<?php
/*
 * perf counterpart of php-src's benchmark/benchmark.php: the same workloads,
 * with the same php-cgi settings, measured with `perf stat` on the real CPU
 * instead of counted by callgrind.
 *
 *   php bench-perf.php <php-cgi> <output.json>
 *
 * Per workload, with and without the tracing JIT, every event perf could count:
 *
 *   value        per request, as benchmark.php computes it: the whole php-cgi
 *                process (start-up and warm-up included) divided by the
 *                measured requests, averaged over the runs
 *   unit         perf's unit: ns for duration_time, msec for task-clock,
 *                none for counters
 *   stddev_pct   run-to-run variation perf reports, in percent of the mean
 *
 * The Symfony Demo gets a freshly cleared and warmed cache before every run,
 * not just before every workload: the first process after a warmup still
 * writes cache files, so a plain `perf stat -r` would measure that in its
 * first repetition only. Those runs are measured one at a time and averaged
 * here, with the same standard error perf would report.
 *
 * Events this machine cannot count (the hardware counters in a VM, say) are
 * null. The defaults are below; override them with PHP_SRC_BENCH_PERF_EVENTS
 * (perf's comma-separated -e syntax) and the number of runs per workload with
 * PHP_SRC_BENCH_PERF_RUNS.
 *
 * Run by bin/bench.sh in the container, which provides the database and the
 * ini (PHPRC), or by bin/bench-macos.sh on a Mac, which sets
 * PHP_SRC_BENCH_STAT to bin/macos/pmcstat -- perf's stand-in there, with its
 * own fixed set of events -- PHP_SRC_BENCH_DIR to the host's checkout, and
 * PHP_SRC_BENCH_REPOS to a checkout of the Symfony Demo and WordPress of its
 * own: Symfony keeps its cache inside the project, and one built on macOS and
 * cleared from a container (or the other way round) breaks.
 */

$benchmarkDir = getenv('PHP_SRC_BENCH_DIR') ?: '/php-src/benchmark';
require_once $benchmarkDir . '/shared.php';

$phpCgi = $argv[1] ?? exit("Usage: bench-perf.php <php-cgi> <output.json>\n");
$outFile = $argv[2] ?? exit("Usage: bench-perf.php <php-cgi> <output.json>\n");

$statCommand = getenv('PHP_SRC_BENCH_STAT') ?: null;
$events = getenv('PHP_SRC_BENCH_PERF_EVENTS')
    ?: 'duration_time,task-clock,cycles,instructions,branches,branch-misses,cache-references,cache-misses';
$runs = (int) (getenv('PHP_SRC_BENCH_PERF_RUNS') ?: 5);
$runs > 0 or exit("PHP_SRC_BENCH_PERF_RUNS must be a positive number.\n");

function measure(
    string $script,
    ?string $cwd = null,
    bool $jit = false,
    int $warmup = 0,
    int $repeat = 1,
    ?Closure $prepare = null,
): array {
    global $runs;

    if ($prepare === null) {
        $events = parsePerfStat(runStat($script, $cwd, $jit, $warmup, $repeat, $runs), $repeat);
        return ['runs' => $runs, 'requests' => $repeat, 'events' => $events];
    }

    $samples = [];
    for ($i = 0; $i < $runs; $i++) {
        $prepare();
        $samples[] = parsePerfStat(runStat($script, $cwd, $jit, $warmup, $repeat, 1), $repeat);
    }
    return ['runs' => $runs, 'requests' => $repeat, 'events' => aggregate($samples)];
}

/* Run php-cgi under perf stat (or its stand-in) and return the CSV it wrote. */
function runStat(string $script, ?string $cwd, bool $jit, int $warmup, int $repeat, int $runs): string {
    global $phpCgi, $statCommand, $events;

    $statFile = tempnam(sys_get_temp_dir(), 'perf');

    runCommand([
        ...($statCommand
            ? [$statCommand, '-o', $statFile, '-r', (string) $runs, '--']
            : ['perf', 'stat', '-x,', '-o', $statFile, '-r', (string) $runs, '-e', $events, '--']),
        $phpCgi,
        '-T' . ($warmup ? $warmup . ',' : '') . $repeat,
        '-d max_execution_time=0',
        '-d opcache.enable=1',
        '-d opcache.jit=' . ($jit ? 'tracing' : 'disable'),
        '-d opcache.jit_buffer_size=128M',
        '-d opcache.validate_timestamps=0',
        $script,
    ], $cwd);

    $stat = file_get_contents($statFile);
    unlink($statFile);
    return $stat;
}

/* Combine single runs as perf stat -r does: the mean, and the standard error
 * of the mean in percent of it. An event missing from any run is null. */
function aggregate(array $samples): array {
    $n = count($samples);
    $result = [];
    foreach ($samples[0] as $event => $first) {
        $values = array_map(fn($sample) => $sample[$event]['value'] ?? null, $samples);
        if ($first === null || in_array(null, $values, true)) {
            $result[$event] = null;
            continue;
        }
        $mean = array_sum($values) / $n;
        $stddev = null;
        if ($n > 1) {
            $variance = array_sum(array_map(fn($v) => ($v - $mean) ** 2, $values)) / ($n - 1);
            $stddev = $mean != 0 ? round(100 * sqrt($variance / $n) / $mean, 2) : 0.0;
        }
        $result[$event] = ['value' => round($mean, 3), 'unit' => $first['unit'], 'stddev_pct' => $stddev];
    }
    return $result;
}

/* perf stat -x, prints one line per event:
 *
 *   value,unit,event[,stddev%],run time,enabled %,metric,metric unit
 *
 * with "<not supported>" or "<not counted>" as the value of an event it could
 * not count, and the stddev column only when -r repeats the command. */
function parsePerfStat(string $stat, int $repeat): array {
    $result = [];
    foreach (explode("\n", $stat) as $line) {
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        $fields = str_getcsv($line, ',', '"', '');
        if (count($fields) < 3) {
            continue;
        }
        [$value, $unit, $event] = $fields;
        /* A counter restricted to user space is reported as cycles:u. */
        $event = preg_replace('/:[ukhGH]+$/', '', $event);
        $stddev = isset($fields[3]) && str_ends_with($fields[3], '%') ? (float) $fields[3] : null;

        $result[$event] = is_numeric($value) ? [
            'value' => round((float) $value / $repeat, 3),
            'unit' => $unit !== '' ? $unit : null,
            'stddev_pct' => $stddev,
        ] : null;
    }
    $result or throw new \Exception("Unexpected perf stat output:\n" . $stat);
    return $result;
}

/* Set-up as in benchmark.php, so this also runs on its own. */
$reposDir = getenv('PHP_SRC_BENCH_REPOS') ?: $benchmarkDir . '/repos';
$symfony = $reposDir . '/symfony-demo-2.2.3';
cloneRepo($symfony, 'https://github.com/php/benchmarking-symfony-demo-2.2.3.git');

/* A freshly built cache before every run, as benchmark.php does before its
 * one, so no run inherits the cache an earlier one left behind. */
function warmSymfony(string $dir): void {
    runCommand([PHP_BINARY, $dir . '/bin/console', 'cache:clear']);
    runCommand([PHP_BINARY, $dir . '/bin/console', 'cache:warmup']);
}

$wordpress = $reposDir . '/wordpress-6.2';
cloneRepo($wordpress, 'https://github.com/php/benchmarking-wordpress-6.2.git');
runCommand([
    PHP_BINARY, '-d error_reporting=0', 'wp-cli.phar', 'core', 'install',
    '--url=wordpress.local', '--title="Wordpress"', '--admin_user=wordpress',
    '--admin_password=wordpress', '--admin_email=benchmark@php.net',
], $wordpress);
runCommand([PHP_BINARY, $wordpress . '/index.php'], $wordpress);

$data = [];
foreach ([false, true] as $jit) {
    $suffix = $jit ? ' JIT' : '';
    $data['Zend/bench.php' . $suffix] = measure(dirname($benchmarkDir) . '/Zend/bench.php', jit: $jit);
    $data['Symfony Demo 2.2.3' . $suffix] = measure(
        $symfony . '/public/index.php', $symfony, $jit, 50, 50, fn() => warmSymfony($symfony));
    $data['Wordpress 6.2' . $suffix] = measure($wordpress . '/index.php', $wordpress, $jit, 50, 50);
}

file_put_contents($outFile, json_encode($data, JSON_PRETTY_PRINT) . "\n");
