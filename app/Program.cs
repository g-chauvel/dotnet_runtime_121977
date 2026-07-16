using System;
using System.IO;
using System.Linq;
using System.Runtime;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

// Minimal reproduction of dotnet/runtime#121977 (no PowerShell required), cross-platform.
//
// Every process calls ProfileOptimization.StartProfile on the SAME profile file under a
// shared root -- exactly what pwsh does at engine init when many sessions share one $HOME.
// MulticoreJitRecorder::WriteOutput writes the file in place (CREATE_ALWAYS, fragmented,
// unlocked), so concurrent writers tear it and a starting process replays a corrupt profile.
//
// Two identical writers do NOT corrupt: interleaving identical bytes yields a valid file.
// Corruption needs writers of DIFFERENT size, so a torn byte-merge leaves a valid header
// over a mismatched body. This app maximizes that variance: even workers write a tiny
// profile, odd workers a large one.
class Program
{
    static int Main(string[] args)
    {
        // Shared profile root. Defaults to ~/.cache/mcjrepro (pwsh-like); override with
        // MCJ_PROFILE_ROOT so the harness can point every worker at one directory.
        string root = Environment.GetEnvironmentVariable("MCJ_PROFILE_ROOT");
        if (string.IsNullOrEmpty(root))
            root = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".cache", "mcjrepro");
        Directory.CreateDirectory(root);

        ProfileOptimization.SetProfileRoot(root);
        ProfileOptimization.StartProfile("StartupProfileData-Repro");

        // Worker index: first command-line arg if given, else WORKER_IDX env var, else 0.
        // (The arg form keeps the Windows driver portable to Windows PowerShell 5.1.)
        int wi;
        if (!(args.Length > 0 && int.TryParse(args[0], out wi)))
            int.TryParse(Environment.GetEnvironmentVariable("WORKER_IDX"), out wi);
        int sleepMs = int.TryParse(Environment.GetEnvironmentVariable("SLEEP_MS"), out var s) ? s : 200;
        Thread.Sleep(sleepMs);

        long acc = 0;
        if ((wi & 1) == 0)
        {
            // MINIMAL profile: ~one JIT'd method -> tiny WriteOutput.
            acc += Math.Abs(wi) + 1;
        }
        else
        {
            // MAXIMAL profile: many distinct methods across many assemblies -> large,
            // many-fragment WriteOutput. The size delta vs the minimal workers is what
            // makes an interleaved concurrent write corrupt rather than coincide.
            acc += Regex.Matches("a1b2c3d4e5f6g7h8", "[0-9]").Count;
            acc += Regex.IsMatch("foo@bar.com", "^[^@]+@[^@]+$") ? 1 : 0;
            string json = JsonSerializer.Serialize(new { a = wi, b = new[] { 1, 2, 3, 4 }, c = "x", d = new { e = 5 } });
            using (var doc = JsonDocument.Parse(json)) acc += doc.RootElement.GetProperty("a").GetInt32();
            acc += (int)Enumerable.Range(1, 200).Where(x => x % 3 == 0).Select(x => Math.Sqrt(x)).Sum();
            var dict = Enumerable.Range(0, 100).ToDictionary(x => "k" + x, x => x * x);
            acc += dict.Count(kv => kv.Value % 7 == 0);
            // Enumerate a directory that exists on every OS (the shared framework dir),
            // to JIT a bit of I/O code and grow the profile portably.
            string scanDir = System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory();
            var list = new System.Collections.Generic.List<string>();
            foreach (var f in Directory.EnumerateFileSystemEntries(scanDir)) { list.Add(f); if (list.Count > 30) break; }
            acc += string.Join(";", list).Length;
            acc += Convert.ToBase64String(Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("x", 64)))).Length;
            acc += DateTimeOffset.UtcNow.ToString("o").Length;
            acc += Guid.NewGuid().ToString("N").Length;
            acc += new Uri("https://example.com/path?q=1").Host.Length;
            acc += decimal.Parse("3.14159", System.Globalization.CultureInfo.InvariantCulture).ToString().Length;
        }

        return acc > 0 ? 0 : 1;
    }
}
