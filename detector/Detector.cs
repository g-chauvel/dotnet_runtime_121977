using System;
using System.Diagnostics;
using System.IO;

// Reader-side detector for dotnet/runtime#121977, shared by the Linux and Windows runners.
// The fix's contract is "a reader never observes a non-atomic intermediate state", so this
// measures the defect at its source instead of waiting for the flaky downstream JIT crash.
// It opens the shared profile in a tight loop and counts:
//   INCOMPLETE        = file smaller than the 64-byte header (an unpatched runtime truncates
//                       the shared file then regrows it; a fixed runtime never does).
//   TORN              = >=64 bytes but header invalid -> a torn merge of two concurrent writers.
//   SHARING_VIOLATION = the open was refused while a writer held the file. Windows only: the
//                       in-place write opens deny-share (_wfopen_s), so a reader is turned away
//                       instead of seeing torn bytes. Always 0 on Linux, where the profile is
//                       opened with plain fopen, which has no sharing semantics.
// exit 2 if any of those were observed; 0 if the reader always read a complete, valid profile;
// exit 3 if it never managed a single valid read (no profile written at all -- e.g. MulticoreJIT
// silently disabled below 2 CPUs): "nothing happened" must not pass as "atomic".
//
// Like the runtime's player, this validates the HEADER only: it proves the writer publishes
// atomically (no truncated/torn intermediate states), not that a reader survives a profile
// with a valid header and a torn body (see README, "What this measures").
//
// Header layout mirrored from src/coreclr/vm/multicorejitimpl.h (HeaderRecord, 64B):
//   recordID@0 == Pack8_24(1,64)=0x01000040 ; version@4 == 102 ; moduleCount@12 ;
//   methodCount@16 ; MAX_MODULES=0x1000 ; MAX_METHODS=0xffff.
class Detector
{
    const int ERROR_SHARING_VIOLATION = 32;
    const int ERROR_LOCK_VIOLATION = 33;

    static int Main(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("usage: detector <path> <durationMs>"); return 1; }
        string path = args[0];
        long dur = long.Parse(args[1]);
        byte[] buf = new byte[8192];
        long samples = 0, ok = 0, incomplete = 0, torn = 0, sharing = 0, missing = 0;
        var sw = Stopwatch.StartNew();
        while (sw.ElapsedMilliseconds < dur)
        {
            try
            {
                // Generous reader share flags: any contention comes from the WRITER's
                // deny-share open (Windows), not from us.
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                              FileShare.ReadWrite | FileShare.Delete);
                int n = fs.Read(buf, 0, buf.Length);
                samples++;
                if (n < 64) { incomplete++; continue; }
                uint recordID  = BitConverter.ToUInt32(buf, 0);
                uint version   = BitConverter.ToUInt32(buf, 4);
                uint modCount  = BitConverter.ToUInt32(buf, 12);
                uint methCount = BitConverter.ToUInt32(buf, 16);
                if (recordID != 0x01000040u || version != 102u || modCount > 0x1000u || methCount > 0xffffu) { torn++; continue; }
                ok++;
            }
            catch (FileNotFoundException) { missing++; }
            catch (DirectoryNotFoundException) { missing++; }
            catch (IOException ex)
            {
                int code = ex.HResult & 0xFFFF;
                if (code == ERROR_SHARING_VIOLATION || code == ERROR_LOCK_VIOLATION) sharing++;
                else missing++;
            }
        }
        Console.WriteLine($"DETECTOR path={path} dur={dur}ms samples={samples} OK={ok} INCOMPLETE={incomplete} TORN={torn} SHARING_VIOLATION={sharing} missing={missing}");
        if (incomplete + torn + sharing > 0) return 2;
        // Exit 0 must mean "writes were observed and were atomic", not "nothing happened".
        if (ok == 0) return 3;
        return 0;
    }
}
