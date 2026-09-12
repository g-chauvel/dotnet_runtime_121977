#!/usr/bin/env bash
# Synthetic guard tests: fake SDK/detector/writers, real delay shim and unchanged driver.
# These do not build .NET apps or establish runtime correctness.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'echo "writer-report test evidence left at: $WORK"' EXIT
cat > "$WORK/host.c" <<'C'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

static void put32(unsigned char* b, int offset, unsigned n) {
    for (int i = 0; i < 4; i++) b[offset + i] = n >> (8 * i);
}
static void append_report(const char* text) {
    int fd = open(getenv("MCJ_DELAY_REPORT"), O_CREAT | O_APPEND | O_WRONLY, 0600);
    if (fd < 0 || write(fd, text, strlen(text)) != (ssize_t)strlen(text)) exit(7);
    close(fd);
}
int main(int argc, char** argv) {
    if (argc < 2) return 7;
    if (!strcmp(argv[1], "--version")) {
        puts("synthetic host -- no .NET SDK/build"); return 0;
    }
    if (!strcmp(argv[1], "build")) {
        const char* output = NULL;
        int detector = 0;
        for (int i = 2; i < argc; i++) {
            if (strstr(argv[i], "detector.csproj")) detector = 1;
            if (!strcmp(argv[i], "-o") && i + 1 < argc) output = argv[++i];
        }
        if (!output) return 7;
        mkdir(output, 0700);
        char file[4096];
        snprintf(file, sizeof(file), "%s/%s", output, detector ? "detector.dll" : "mcjrepro.dll");
        int fd = open(file, O_CREAT | O_WRONLY, 0600);
        if (fd < 0) return 7;
        close(fd); return 0;
    }
    const char* scenario = getenv("REPORT_TEST_CASE");
    if (strstr(argv[1], "detector.dll")) {
        if (argc == 4) return 0; // Synthetic static-profile check.
        if (argc != 5) return 7;
        int fd = open(argv[4], O_CREAT | O_WRONLY, 0600);
        if (fd < 0) return 7;
        close(fd); usleep(700000);
        return !strcmp(scenario, "anomaly_crash") ? 2 : 0;
    }
    unsigned char data[116] = {0}; // Structurally valid, not semantically playable.
    put32(data, 0, 0x01000040); put32(data, 4, 103);
    put32(data, 12, 1); put32(data, 16, 1);
    put32(data, 64, 0x0200002c); put32(data, 108, 0x04000000);
    put32(data, 112, 0x06000001);
    const char* root = getenv("MCJ_PROFILE_ROOT");
    mkdir(root, 0700);
    char final[4096], temporary[4096];
    snprintf(final, sizeof(final), "%s/StartupProfileData-Repro", root);
    snprintf(temporary, sizeof(temporary), "%s/writer.%s.tmp", root, getenv("WORKER_IDX") ?: "seed");
    int seed = !strcmp(getenv("SLEEP_MS"), "5");
    int first = !seed && !strcmp(getenv("WORKER_IDX"), "0");
    int crash = first && (!strcmp(scenario, "crash_no_report") || !strcmp(scenario, "anomaly_crash"));
    if (!seed && !strcmp(scenario, "no_publication")) {
        FILE* fp = fopen("/dev/null", "rb"); if (!fp) return 7;
        fclose(fp); return 0;
    }
    if (!seed && !strcmp(scenario, "late")) usleep(900000);
    const char* path = seed || crash || !strcmp(scenario, "nonzero") ? final : temporary;
    if (!seed && first && !strcmp(scenario, "missing_zero_exit")) {
        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
        if (fd < 0 || write(fd, data, sizeof(data)) != sizeof(data)) return 7;
        close(fd); // No stdio: shim report deliberately absent, exit still zero.
    } else {
        FILE* fp = fopen(path, "wb"); if (!fp) return 7;
        if (fwrite(data, 1, sizeof(data), fp) != sizeof(data) || fclose(fp)) return 7;
    }
    if (crash) _exit(9); // Lose the real shim's positive atexit counters.
    if (path == temporary && rename(temporary, final)) return 7;
    if (!seed && !strcmp(scenario, "extra_report")) append_report("open=0 write=0\n");
    if (!seed && !strcmp(scenario, "malformed")) append_report("invalid\n");
    return !seed && !strcmp(scenario, "failed_with_report") ? 9 : 0;
}
C
gcc -O0 -fno-builtin "$WORK/host.c" -o "$WORK/dotnet"
for scenario in clean crash_no_report missing_zero_exit extra_report failed_with_report malformed nonzero no_publication late anomaly_crash; do
    expected=1
    [ "$scenario" != clean ] || expected=0
    [ "$scenario" != anomaly_crash ] || expected=2
    mkdir "$WORK/$scenario"
    rc=0
    ( unset LD_PRELOAD MCJ_DELAY_REPORT
      export REPORT_TEST_CASE="$scenario" TMPDIR="$WORK/$scenario"
      export DOTNET_SDK="$WORK/dotnet" DOTNET_ROOT="$WORK"
      export DUR_MS=350 WRITERS=2
      bash "$HERE/run.sh"
    ) > "$WORK/$scenario.log" 2>&1 || rc=$?
    if [ "$rc" -ne "$expected" ]; then
        cat "$WORK/$scenario.log"
        echo "FAIL: $scenario expected exit $expected, got $rc"
        exit 1
    fi
    echo "PASS: $scenario (exit $rc)"
done
