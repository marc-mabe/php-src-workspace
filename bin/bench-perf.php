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
 * Events this machine cannot count (the hardware counters in a VM, say) are
 * null. The defaults are below; override them with PHP_SRC_BENCH_PERF_EVENTS
 * (perf's comma-separated -e syntax) and the number of runs per workload with
 * PHP_SRC_BENCH_PERF_RUNS.
 *
 * Run by bin/bench.sh in the container, which provides the database and the
 * ini (PHPRC), or by bin/bench-macos.sh on a Mac, which sets
 * PHP_SRC_BENCH_STAT to bin/macos/pmcstat -- perf's stand-in there, with its
 * own fixed set of events -- and PHP_SRC_BENCH_DIR to the host's checkout.
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

function measure(string $script, ?string $cwd = null, bool $jit = false, int $warmup = 0, int $repeat = 1): array {
    global $phpCgi, $statCommand, $events, $runs;

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

    return ['runs' => $runs, 'requests' => $repeat, 'events' => parsePerfStat($stat, $repeat)];
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
$symfony = $benchmarkDir . '/repos/symfony-demo-2.2.3';
cloneRepo($symfony, 'https://github.com/php/benchmarking-symfony-demo-2.2.3.git');
runCommand([PHP_BINARY, $symfony . '/bin/console', 'cache:clear']);
runCommand([PHP_BINARY, $symfony . '/bin/console', 'cache:warmup']);

$wordpress = $benchmarkDir . '/repos/wordpress-6.2';
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
    $data['Symfony Demo 2.2.3' . $suffix] = measure($symfony . '/public/index.php', $symfony, $jit, 50, 50);
    $data['Wordpress 6.2' . $suffix] = measure($wordpress . '/index.php', $wordpress, $jit, 50, 50);
}

file_put_contents($outFile, json_encode($data, JSON_PRETTY_PRINT) . "\n");
