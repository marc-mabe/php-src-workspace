<?php
/*
 * Memory counterpart of php-src's benchmark/benchmark.php: the same workloads,
 * with the same php-cgi settings, measured for memory instead of instructions.
 *
 *   php bench-memory.php <php-cgi> <output.json>
 *
 * Per workload, with and without the tracing JIT:
 *
 *   max_rss_kib       peak resident set of the php-cgi process (GNU time),
 *                     including opcache's shared memory and the JIT buffer as
 *                     far as they were touched
 *   zend_peak         memory_get_peak_usage() of the last request: what PHP
 *                     code and the engine allocated through the Zend allocator
 *   zend_peak_real    memory_get_peak_usage(true): the same in the allocator's
 *                     2 MiB chunks, i.e. what it took from the system
 *
 * Run by bin/bench.sh, which provides the database and the ini (PHPRC).
 */

$benchmarkDir = '/php-src/benchmark';
require_once $benchmarkDir . '/shared.php';

$phpCgi = $argv[1] ?? exit("Usage: bench-memory.php <php-cgi> <output.json>\n");
$outFile = $argv[2] ?? exit("Usage: bench-memory.php <php-cgi> <output.json>\n");

/* Each request's shutdown appends its Zend peak to this file. A shutdown
 * function rather than auto_append_file, which a script that exit()s skips. */
$peakFile = tempnam(sys_get_temp_dir(), 'peak');
$prependFile = tempnam(sys_get_temp_dir(), 'prepend');
file_put_contents($prependFile, '<?php register_shutdown_function(static function () {
    file_put_contents(' . var_export($peakFile, true) . ',
        memory_get_peak_usage() . " " . memory_get_peak_usage(true) . "\n", FILE_APPEND);
});');

function measure(string $script, ?string $cwd = null, bool $jit = false, int $warmup = 0, int $repeat = 1): array {
    global $phpCgi, $peakFile, $prependFile;

    file_put_contents($peakFile, '');
    $timeFile = tempnam(sys_get_temp_dir(), 'time');

    runCommand([
        '/usr/bin/time', '-f', '%M', '-o', $timeFile,
        $phpCgi,
        '-T' . ($warmup ? $warmup . ',' : '') . $repeat,
        '-d max_execution_time=0',
        '-d opcache.enable=1',
        '-d opcache.jit=' . ($jit ? 'tracing' : 'disable'),
        '-d opcache.jit_buffer_size=128M',
        '-d opcache.validate_timestamps=0',
        '-d auto_prepend_file=' . $prependFile,
        $script,
    ], $cwd);

    $peaks = file($peakFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    [$peak, $peakReal] = array_map('intval', explode(' ', end($peaks) ?: '0 0'));
    $maxRss = (int) trim(file_get_contents($timeFile));
    unlink($timeFile);

    return [
        'max_rss_kib' => $maxRss,
        'zend_peak' => $peak,
        'zend_peak_real' => $peakReal,
    ];
}

/* Set-up as in benchmark.php, so this also runs on its own. */
$symfony = $benchmarkDir . '/repos/symfony-demo-2.2.3';
cloneRepo($symfony, 'https://github.com/php/benchmarking-symfony-demo-2.2.3.git');

/* A freshly built cache before every measurement, as benchmark.php does, so
 * the JIT run does not inherit the cache the run before it left behind. */
function warmSymfony(string $dir): void {
    runCommand([PHP_BINARY, $dir . '/bin/console', 'cache:clear']);
    runCommand([PHP_BINARY, $dir . '/bin/console', 'cache:warmup']);
}

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
    $data['Zend/bench.php' . $suffix] = measure('/php-src/Zend/bench.php', jit: $jit);
    warmSymfony($symfony);
    $data['Symfony Demo 2.2.3' . $suffix] = measure($symfony . '/public/index.php', $symfony, $jit, 50, 50);
    $data['Wordpress 6.2' . $suffix] = measure($wordpress . '/index.php', $wordpress, $jit, 50, 50);
}

unlink($peakFile);
unlink($prependFile);

file_put_contents($outFile, json_encode($data, JSON_PRETTY_PRINT) . "\n");
