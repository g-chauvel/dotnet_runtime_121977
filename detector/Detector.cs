using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;

// Reader-side detector for dotnet/runtime#121977, shared by the Linux and Windows runners.
// The fix's contract is "a reader never observes a non-atomic intermediate state", so this
// measures the defect at its source instead of waiting for the flaky downstream JIT crash.
// It opens the shared profile in a tight loop and counts:
//   INCOMPLETE        = file or read shorter than the 64-byte header (an unpatched runtime
//                       truncates the shared file then regrows it; a fixed runtime never does).
//   TORN              = header or complete record stream is structurally invalid, changes size
//                       while being read, or disagrees with the record counts in the header.
//   SHARING_VIOLATION = the open was refused while a writer held the file. Windows only: the
//                       in-place write opens deny-share (_wfopen_s), so a reader is turned away
//                       instead of seeing torn bytes. Always 0 on Linux, where the profile is
//                       opened with plain fopen, which has no sharing semantics.
//   MISSING           = the seeded final path disappeared during the live phase.
// exit 2 if any non-atomic state was observed; 0 if every read was complete and valid; 1 for
// an unexpected I/O error; 3 if it never managed a single valid read (no profile written at
// all -- e.g. MulticoreJIT silently disabled below 2 CPUs): "nothing happened" must not pass.
//
// The structural validator mirrors the on-disk grammar in multicorejitimpl.h. It accepts
// version 102 from the stock runtime and version 103 from the atomic-publication fix so one
// harness can compare both cohorts. See README, "What this measures", for the remaining
// semantic-replay limitation.
class Detector
{
    const int HeaderSize = 64;
    const int ModuleRecordFixedSize = 44;
    const int ModuleNameLengthOffset = 38;
    const int AssemblyNameLengthOffset = 40;
    const int MaxProfileSize = 64 * 1024 * 1024;
    const uint LegacyProfileVersion = 102;
    const uint AtomicProfileVersion = 103;
    const uint MaxModules = 0x1000;
    const uint MaxMethods = 0xffff;

    const uint ModuleRecordId = 2;
    const uint ModuleDependencyRecordId = 3;
    const uint MethodRecordId = 4;
    const uint GenericMethodRecordId = 5;

    const int ERROR_SHARING_VIOLATION = 32;
    const int ERROR_LOCK_VIOLATION = 33;

    static int Align4(int value) => (value + 3) & ~3;

    static bool IsStructurallyValidProfile(ReadOnlySpan<byte> profile)
    {
        if (profile.Length <= HeaderSize)
            return false;

        uint headerRecordId = BinaryPrimitives.ReadUInt32LittleEndian(profile);
        uint version = BinaryPrimitives.ReadUInt32LittleEndian(profile.Slice(4));
        uint expectedModules = BinaryPrimitives.ReadUInt32LittleEndian(profile.Slice(12));
        uint expectedMethods = BinaryPrimitives.ReadUInt32LittleEndian(profile.Slice(16));
        uint expectedDependencies = BinaryPrimitives.ReadUInt32LittleEndian(profile.Slice(20));

        if (headerRecordId != 0x01000040u ||
            (version != LegacyProfileVersion && version != AtomicProfileVersion) ||
            expectedModules > MaxModules || expectedMethods > MaxMethods)
        {
            return false;
        }

        int offset = HeaderSize;
        uint modules = 0;
        uint methods = 0;
        uint dependencies = 0;
        bool sawNonModuleRecord = false;

        while (offset < profile.Length)
        {
            int remaining = profile.Length - offset;
            if (remaining < sizeof(uint))
                return false;

            uint data1 = BinaryPrimitives.ReadUInt32LittleEndian(profile.Slice(offset));
            uint recordType = data1 >> 24;
            int recordLength;

            switch (recordType)
            {
                case ModuleRecordId:
                {
                    if (sawNonModuleRecord || modules >= expectedModules)
                        return false;

                    recordLength = (int)(data1 & 0x00ff_ffffu);
                    if (recordLength < ModuleRecordFixedSize ||
                        (recordLength & 3) != 0 || recordLength > remaining)
                    {
                        return false;
                    }

                    ushort moduleNameLength = BinaryPrimitives.ReadUInt16LittleEndian(profile.Slice(offset + ModuleNameLengthOffset));
                    ushort assemblyNameLength = BinaryPrimitives.ReadUInt16LittleEndian(profile.Slice(offset + AssemblyNameLengthOffset));
                    int expectedLength = ModuleRecordFixedSize + Align4(moduleNameLength) + Align4(assemblyNameLength);
                    if (recordLength != expectedLength)
                        return false;

                    modules++;
                    break;
                }

                case ModuleDependencyRecordId:
                    sawNonModuleRecord = true;
                    recordLength = sizeof(uint);
                    dependencies++;
                    if ((data1 & 0xffffu) >= expectedModules)
                        return false;
                    break;

                case MethodRecordId:
                    sawNonModuleRecord = true;
                    recordLength = 2 * sizeof(uint);
                    methods++;
                    if ((data1 & 0xffffu) >= expectedModules)
                        return false;
                    break;

                case GenericMethodRecordId:
                {
                    sawNonModuleRecord = true;
                    if (remaining < sizeof(uint) + sizeof(ushort))
                        return false;

                    ushort signatureLength = BinaryPrimitives.ReadUInt16LittleEndian(profile.Slice(offset + sizeof(uint)));
                    recordLength = Align4(sizeof(uint) + sizeof(ushort) + signatureLength);
                    methods++;
                    if ((data1 & 0xffffu) >= expectedModules)
                        return false;
                    break;
                }

                default:
                    return false;
            }

            if (recordLength > remaining || (recordLength & 3) != 0)
                return false;

            offset += recordLength;
        }

        return offset == profile.Length &&
               modules == expectedModules &&
               methods == expectedMethods &&
               dependencies == expectedDependencies;
    }

    static int Main(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("usage: detector <path> <durationMs> [readyPath]"); return 1; }
        string path = args[0];
        long dur = long.Parse(args[1]);
        byte[] buf = new byte[64 * 1024];
        long samples = 0, ok = 0, incomplete = 0, torn = 0, sharing = 0, missing = 0, ioErrors = 0;

        // Let the driver start writers only after the detector is initialized. The
        // ready file is optional so the detector remains convenient to run by hand.
        if (args.Length >= 3)
            File.WriteAllText(args[2], string.Empty);

        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < dur)
        {
            try
            {
                // Generous reader share flags: any contention comes from the WRITER's
                // deny-share open (Windows), not from us.
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete);
                samples++;

                long observedLength = fs.Length;
                if (observedLength < HeaderSize) { incomplete++; continue; }
                if (observedLength > MaxProfileSize) { torn++; continue; }

                int expectedLength = (int)observedLength;
                if (buf.Length < expectedLength)
                    Array.Resize(ref buf, expectedLength);

                // Read the complete snapshot exposed by this handle. A short read, or
                // another byte appearing beyond the observed length, means an in-place
                // writer changed the file while the detector was consuming it.
                int n = fs.ReadAtLeast(buf.AsSpan(0, expectedLength), expectedLength, throwOnEndOfStream: false);
                if (n < HeaderSize) { incomplete++; continue; }
                if (n != expectedLength || fs.ReadByte() != -1) { torn++; continue; }
                if (!IsStructurallyValidProfile(buf.AsSpan(0, n))) { torn++; continue; }
                ok++;
            }
            catch (FileNotFoundException) { missing++; }
            catch (DirectoryNotFoundException) { missing++; }
            catch (IOException ex)
            {
                int code = ex.HResult & 0xFFFF;
                if (code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION) sharing++;
                else ioErrors++;
            }
        }
        Console.WriteLine($"DETECTOR path={path} dur={dur}ms samples={samples} OK={ok} INCOMPLETE={incomplete} TORN={torn} SHARING_VIOLATION={sharing} MISSING={missing} IO_ERROR={ioErrors}");
        // An unexpected I/O error is a harness failure, not evidence for either verdict.
        if (ioErrors > 0) return 1;
        // The profile is seeded before sampling starts, so a missing observation is also
        // a non-atomic state rather than an expected startup race.
        if (incomplete + torn + sharing + missing > 0) return 2;
        // Exit 0 must mean "writes were observed and were atomic", not "nothing happened".
        if (ok == 0) return 3;
        return 0;
    }
}
