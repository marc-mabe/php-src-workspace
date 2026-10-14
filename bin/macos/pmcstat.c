/*
 * A small `perf stat` for macOS: run a command, read the CPU counters the
 * kernel kept for it, and print them in perf stat's CSV format, so
 * bin/bench-perf.php reads either.
 *
 *   pmcstat [-r runs] [-o file] -- command [args...]
 *
 * The counters come from proc_pid_rusage(RUSAGE_INFO_V6), which needs no root:
 * XNU counts cycles and instructions per process on Apple Silicon, split by
 * performance and efficiency cores, and estimates the energy used. They are
 * read from the exited child before it is reaped (waitid with WNOWAIT).
 * Branch and cache events would need the private kperf framework and root.
 *
 * cycles and instructions include what the kernel executes on the process's
 * behalf: an access() call costs 5,000 to 13,000 instructions depending on
 * the path, more with an Endpoint Security client such as an EDR agent
 * inspecting file events. How
 * much varies with the system's state, so workloads heavy on file system calls
 * drift between runs while the PHP code they run does not change. There is no
 * user-mode-only count without root; user-time and system-time, which macOS
 * does split, show how large the kernel's share is.
 *
 * Like perf stat -r, each event is the mean over the runs, followed by the
 * standard error of that mean in percent. ASLR is switched off for the child,
 * as bench.sh does with setarch -R on Linux.
 *
 * Build: clang -O2 -o pmcstat pmcstat.c
 */

#include <errno.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* Private posix_spawn flag (<spawn_private.h>), what lldb uses for the same. */
#ifndef _POSIX_SPAWN_DISABLE_ASLR
#define _POSIX_SPAWN_DISABLE_ASLR 0x0100
#endif

enum {
    DURATION, TASK_CLOCK, USER_TIME, SYSTEM_TIME,
    CYCLES, INSTRUCTIONS, P_CYCLES, P_INSTRUCTIONS, ENERGY,
    N_EVENTS
};

static const struct {
    const char *name;
    const char *unit;
} events[N_EVENTS] = {
    [DURATION] = {"duration_time", "ns"},
    [TASK_CLOCK] = {"task-clock", "msec"},
    [USER_TIME] = {"user-time", "msec"},
    [SYSTEM_TIME] = {"system-time", "msec"},
    [CYCLES] = {"cycles", ""},
    [INSTRUCTIONS] = {"instructions", ""},
    [P_CYCLES] = {"p-cycles", ""},
    [P_INSTRUCTIONS] = {"p-instructions", ""},
    [ENERGY] = {"energy", "nJ"},
};

static void usage(void) {
    fputs("Usage: pmcstat [-r runs] [-o file] -- command [args...]\n", stderr);
    exit(2);
}

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (double) ts.tv_sec * 1e9 + (double) ts.tv_nsec;
}

/* Run the command once and fill in one value per event. Exits with the
 * command's status if it fails, as perf stat does. */
static void run_once(char **argv, double *out) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, _POSIX_SPAWN_DISABLE_ASLR);

    double start = now_ns();
    pid_t pid;
    int err = posix_spawnp(&pid, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (err) {
        fprintf(stderr, "pmcstat: %s: %s\n", argv[0], strerror(err));
        exit(127);
    }

    siginfo_t si;
    while (waitid(P_PID, pid, &si, WEXITED | WNOWAIT) == -1) {
        if (errno != EINTR) {
            perror("pmcstat: waitid");
            exit(1);
        }
    }
    double end = now_ns();

    struct rusage_info_v6 ri;
    if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *) &ri) != 0) {
        perror("pmcstat: proc_pid_rusage");
        exit(1);
    }

    int status;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "pmcstat: %s exited with status %d\n", argv[0],
                WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
        exit(WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    }

    /* ri_user_time and ri_system_time are in mach absolute time units. */
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double user_ms = (double) ri.ri_user_time * tb.numer / tb.denom / 1e6;
    double system_ms = (double) ri.ri_system_time * tb.numer / tb.denom / 1e6;

    out[DURATION] = end - start;
    out[TASK_CLOCK] = user_ms + system_ms;
    out[USER_TIME] = user_ms;
    out[SYSTEM_TIME] = system_ms;
    out[CYCLES] = (double) ri.ri_cycles;
    out[INSTRUCTIONS] = (double) ri.ri_instructions;
    out[P_CYCLES] = (double) ri.ri_pcycles;
    out[P_INSTRUCTIONS] = (double) ri.ri_pinstructions;
    out[ENERGY] = (double) ri.ri_energy_nj;
}

int main(int argc, char **argv) {
    int runs = 1;
    const char *outPath = NULL;
    int opt;

    while ((opt = getopt(argc, argv, "+r:o:")) != -1) {
        switch (opt) {
            case 'r':
                runs = atoi(optarg);
                if (runs < 1) usage();
                break;
            case 'o':
                outPath = optarg;
                break;
            default:
                usage();
        }
    }
    if (optind >= argc) usage();
    char **cmd = argv + optind;

    double sum[N_EVENTS] = {0}, sumsq[N_EVENTS] = {0};
    for (int i = 0; i < runs; i++) {
        double v[N_EVENTS];
        run_once(cmd, v);
        for (int e = 0; e < N_EVENTS; e++) {
            sum[e] += v[e];
            sumsq[e] += v[e] * v[e];
        }
    }

    FILE *out = stderr;
    if (outPath && !(out = fopen(outPath, "w"))) {
        perror(outPath);
        return 1;
    }

    /* perf stat -x, layout: value,unit,event,stddev%,run time,enabled % */
    for (int e = 0; e < N_EVENTS; e++) {
        double mean = sum[e] / runs;
        double rel = 0;
        if (runs > 1 && mean != 0) {
            double var = (sumsq[e] - sum[e] * sum[e] / runs) / (runs - 1);
            rel = 100 * sqrt(var > 0 ? var / runs : 0) / mean;
        }
        fprintf(out, "%.2f,%s,%s,%.2f%%,,100.00\n", mean, events[e].unit, events[e].name, rel);
    }

    if (out != stderr) fclose(out);
    return 0;
}
