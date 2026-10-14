#!/usr/bin/env php
<?php
/*
 * Compare two bench.sh / bench-macos.sh result directories.
 *
 *   bench-diff.php [-o prefix] <base> <head>
 *
 * <base> and <head> are result directories, or their names under
 * bench-results/. Every benchmark both have (callgrind.json, memory.json,
 * perf.json) is compared workload by workload and metric by metric; lower is
 * better for all of them.
 *
 * Writes <prefix>.json and <prefix>.md -- by default diff-vs-<base name> in
 * the head directory -- and prints the Markdown.
 *
 * A change counts as significant when it exceeds a threshold (threshold_pct
 * in the JSON, the ± figure in the Markdown):
 *
 *   perf       twice the two runs' combined noise, from the standard error
 *              perf stat reports; with a single run there is no noise
 *              estimate, and significance stays unknown (null)
 *   callgrind  a fixed noise floor per metric, below, measured by
 *   memory     comparing repeated runs of one build: these numbers are
 *              stable, but not exactly reproducible
 *
 * Needs PHP 8.1 or later; any build works, including the host's.
 */

const BENCHMARKS = [
    'callgrind' => 'callgrind: instructions per request',
    'memory' => 'memory: peak usage',
    'perf' => 'perf: per request',
];

/* Unit and noise floor (in percent) of the fixed-format benchmarks' metrics;
 * perf.json carries its own units and noise. The floors are what back-to-back
 * runs of one build differed by, with some margin:
 *
 *   max_rss_kib     up to 1% (page faults, the kernel's accounting)
 *   zend_peak       up to 0.02%: a few hundred bytes, e.g. from timestamps
 *   zend_peak_real  never: it moves in 2 MiB chunks
 */
const METRICS = [
    'callgrind' => [
        'instructions' => [null, 0.1],
    ],
    'memory' => [
        'max_rss_kib' => ['KiB', 2.0],
        'zend_peak' => ['B', 0.1],
        'zend_peak_real' => ['B', 0.0],
    ],
];

const SIGNIFICANCE = 2.0;

function usage(int $status): never {
    fwrite($status ? STDERR : STDOUT, "Usage: bench-diff.php [-o prefix] <base> <head>\n");
    exit($status);
}

function fail(string $message): never {
    fwrite(STDERR, $message . "\n");
    exit(1);
}

function resolveDir(string $arg): string {
    $resultsDir = dirname(__DIR__) . '/bench-results';
    foreach ([$arg, $resultsDir . '/' . $arg] as $candidate) {
        if (is_dir($candidate)) {
            return realpath($candidate);
        }
    }
    fail("Not a result directory: $arg");
}

function readJson(string $file): ?array {
    if (!is_file($file)) {
        return null;
    }
    return json_decode(file_get_contents($file), true, flags: JSON_THROW_ON_ERROR);
}

/* Flatten a benchmark's JSON into workload => metric => [value, unit, noise %],
 * whatever file it came from. */
function readBenchmark(string $dir, string $name): ?array {
    $data = readJson("$dir/$name.json");
    if ($data === null) {
        return null;
    }

    $result = [];
    foreach ($data as $workload => $metrics) {
        /* callgrind.json also holds "branch" when CI sets GITHUB_REF_NAME. */
        if (!is_array($metrics)) {
            continue;
        }
        if ($name === 'perf') {
            foreach ($metrics['events'] as $event => $stat) {
                $result[$workload][$event] = $stat === null ? null : [
                    'value' => (float) $stat['value'],
                    'unit' => $stat['unit'],
                    'noise_pct' => $stat['stddev_pct'],
                    'floor_pct' => null,
                ];
            }
            $result[$workload]['#runs'] = $metrics['runs'] ?? null;
        } else {
            foreach ($metrics as $metric => $value) {
                [$unit, $floor] = METRICS[$name][$metric] ?? [null, 0.0];
                $result[$workload][$metric] = [
                    'value' => (float) $value,
                    'unit' => $unit,
                    'noise_pct' => null,
                    'floor_pct' => $floor,
                ];
            }
        }
    }
    return $result;
}

function describe(string $dir): array {
    $meta = readJson("$dir/meta.json") ?? [];
    return [
        'dir' => basename($dir),
        'commit' => $meta['commit'] ?? null,
        'branch' => $meta['branch'] ?? null,
        'host' => $meta['host'] ?? null,
        'backend' => $meta['backend'] ?? null,
        'arch' => $meta['arch'] ?? null,
        'cpu' => $meta['cpu'] ?? null,
        'php' => $meta['php'] ?? null,
        'compiler' => $meta['compiler'] ?? null,
        'date' => $meta['date'] ?? null,
    ];
}

function compareMetric(?array $base, ?array $head): ?array {
    if ($base === null || $head === null) {
        return null;
    }
    $delta = $head['value'] - $base['value'];
    $deltaPct = $base['value'] != 0 ? 100 * $delta / $base['value'] : null;

    $noise = $threshold = null;
    if ($base['floor_pct'] !== null) {
        $threshold = $base['floor_pct'];
    } elseif ($base['noise_pct'] !== null && $head['noise_pct'] !== null) {
        $noise = sqrt($base['noise_pct'] ** 2 + $head['noise_pct'] ** 2);
        $threshold = SIGNIFICANCE * $noise;
    }

    if ($deltaPct === null) {
        $significant = $delta != 0;
    } else {
        $significant = $threshold === null ? null : abs($deltaPct) > $threshold;
    }

    return [
        'unit' => $head['unit'] ?? $base['unit'],
        'base' => $base['value'],
        'head' => $head['value'],
        'delta' => $delta,
        'delta_pct' => $deltaPct === null ? null : round($deltaPct, 3),
        'noise_pct' => $noise === null ? null : round($noise, 3),
        'threshold_pct' => $threshold === null ? null : round($threshold, 3),
        'significant' => $significant,
    ];
}

function compareBenchmark(array $base, array $head, string $name, array &$warnings): array {
    $result = [];
    $runs = [];
    foreach (array_unique([...array_keys($base), ...array_keys($head)]) as $workload) {
        if (!isset($base[$workload], $head[$workload])) {
            $warnings[] = "$name: \"$workload\" is only in the " . (isset($base[$workload]) ? 'base' : 'head') . ' run.';
            continue;
        }
        /* Only perf.json records how often each workload ran. */
        if (isset($base[$workload]['#runs'], $head[$workload]['#runs'])) {
            $runs[$base[$workload]['#runs'] . ' and ' . $head[$workload]['#runs']] = [
                $base[$workload]['#runs'], $head[$workload]['#runs'],
            ];
        }
        unset($base[$workload]['#runs'], $head[$workload]['#runs']);

        foreach (array_unique([...array_keys($base[$workload]), ...array_keys($head[$workload])]) as $metric) {
            $diff = compareMetric($base[$workload][$metric] ?? null, $head[$workload][$metric] ?? null);
            if ($diff !== null) {
                $result[$workload][$metric] = $diff;
            }
        }
    }

    $single = false;
    foreach ($runs as [$baseRuns, $headRuns]) {
        if ($baseRuns !== $headRuns) {
            $warnings[] = "$name: the base run measured each workload over $baseRuns run(s), the head run over $headRuns.";
        }
        $single = $single || $baseRuns === 1 || $headRuns === 1;
    }
    if ($single) {
        $warnings[] = "$name: a single run has no noise estimate, so whether a change is significant is unknown.";
    }
    return $result;
}

/* ------------------------------------------------------------------ Markdown */

function formatValue(float $value, ?string $unit): string {
    [$value, $unit, $decimals] = match ($unit) {
        'ns' => [$value / 1e6, 'ms', 3],
        'msec' => [$value, 'ms', 3],
        'nJ' => [$value / 1e6, 'mJ', 3],
        'B' => [$value / 1048576, 'MiB', 2],
        'KiB' => [$value / 1024, 'MiB', 2],
        default => [$value, $unit, 0],
    };
    return number_format($value, $decimals, '.', ',') . ($unit !== null && $unit !== '' ? " $unit" : '');
}

function formatPct(array $diff): string {
    if ($diff['delta_pct'] === null) {
        return $diff['delta'] == 0 ? '0' : 'n/a';
    }
    $text = sprintf('%+.2f%%', $diff['delta_pct']);
    if ($diff['threshold_pct'] !== null) {
        $text .= sprintf(' ±%.2f', $diff['threshold_pct']);
    }
    if ($diff['significant'] === null) {
        return $text . ' ?';
    }
    if (!$diff['significant'] || $diff['delta_pct'] == 0) {
        return $text;
    }
    /* Lower is better for every metric. */
    return '**' . $text . '**' . ($diff['delta'] < 0 ? ' ✅' : ' ❌');
}

function cell(string $text): string {
    return str_replace('|', '\|', $text);
}

function describeRun(array $run): string {
    $parts = [];
    $parts[] = $run['commit'] !== null ? '`' . substr($run['commit'], 0, 12) . '`' : '(unknown commit)';
    if ($run['branch'] !== null) {
        $parts[] = '(' . $run['branch'] . ')';
    }
    $where = array_filter([$run['host'], $run['backend'], $run['arch'], $run['cpu']]);
    if ($where) {
        $parts[] = 'on ' . implode(', ', $where);
    }
    return implode(' ', $parts) . ' -- `' . $run['dir'] . '`';
}

function markdown(array $diff): string {
    $md = "# Benchmark diff\n\n";
    $md .= '- **Base:** ' . describeRun($diff['base']) . "\n";
    $md .= '- **Head:** ' . describeRun($diff['head']) . "\n\n";

    foreach ($diff['warnings'] as $warning) {
        $md .= "> [!WARNING]\n> " . $warning . "\n\n";
    }

    if (!$diff['benchmarks']) {
        return $md . "The two runs have no benchmark in common.\n";
    }

    $md .= 'Change from base to head; lower is better everywhere. The ± figure is the threshold a change must'
        . ' exceed to count as significant (bold): ' . SIGNIFICANCE . "× the runs' combined noise for perf, a measured"
        . ' noise floor for callgrind and memory. ? means a single perf run gave no noise estimate.' . "\n";

    foreach ($diff['benchmarks'] as $name => $workloads) {
        $metrics = [];
        foreach ($workloads as $workloadMetrics) {
            $metrics = array_unique([...$metrics, ...array_keys($workloadMetrics)]);
        }

        $md .= "\n## " . BENCHMARKS[$name] . "\n\n";
        $md .= '| Workload | ' . implode(' | ', array_map(cell(...), $metrics)) . " |\n";
        $md .= '|---|' . str_repeat('---:|', count($metrics)) . "\n";
        foreach ($workloads as $workload => $workloadMetrics) {
            $row = [cell($workload)];
            foreach ($metrics as $metric) {
                $row[] = isset($workloadMetrics[$metric]) ? cell(formatPct($workloadMetrics[$metric])) : '';
            }
            $md .= '| ' . implode(' | ', $row) . " |\n";
        }

        $md .= "\n<details><summary>Absolute values</summary>\n\n";
        $md .= "| Workload | Metric | Base | Head | Change |\n|---|---|---:|---:|---:|\n";
        foreach ($workloads as $workload => $workloadMetrics) {
            foreach ($workloadMetrics as $metric => $m) {
                $md .= sprintf("| %s | %s | %s | %s | %s |\n",
                    cell($workload), cell($metric),
                    formatValue($m['base'], $m['unit']), formatValue($m['head'], $m['unit']),
                    cell(formatPct($m)));
            }
        }
        $md .= "\n</details>\n";
    }
    return $md;
}

/* ---------------------------------------------------------------------- main */

$options = getopt('ho:', [], $rest);
if (isset($options['h'])) {
    usage(0);
}
$args = array_slice($argv, $rest);
if (count($args) !== 2) {
    usage(1);
}
[$baseDir, $headDir] = array_map(resolveDir(...), $args);
$prefix = $options['o'] ?? $headDir . '/diff-vs-' . basename($baseDir);

$diff = [
    'base' => describe($baseDir),
    'head' => describe($headDir),
    'warnings' => [],
    'benchmarks' => [],
];

/* Only callgrind compares across machines, and only of one architecture. */
foreach (['backend', 'cpu', 'host'] as $field) {
    if ($diff['base'][$field] !== $diff['head'][$field]) {
        $diff['warnings'][] = sprintf('The runs differ in %s (%s vs %s): only the callgrind numbers compare across machines.',
            $field, $diff['base'][$field] ?? 'unknown', $diff['head'][$field] ?? 'unknown');
        break;
    }
}
if ($diff['base']['arch'] !== $diff['head']['arch']) {
    $diff['warnings'][] = sprintf('The runs are of different architectures (%s vs %s): not even instruction counts compare.',
        $diff['base']['arch'] ?? 'unknown', $diff['head']['arch'] ?? 'unknown');
}

foreach (array_keys(BENCHMARKS) as $name) {
    $base = readBenchmark($baseDir, $name);
    $head = readBenchmark($headDir, $name);
    if ($base === null && $head === null) {
        continue;
    }
    if ($base === null || $head === null) {
        $diff['warnings'][] = "$name.json is only in the " . ($base !== null ? 'base' : 'head') . ' run.';
        continue;
    }
    $diff['benchmarks'][$name] = compareBenchmark($base, $head, $name, $diff['warnings']);
}

$md = markdown($diff);
file_put_contents("$prefix.json", json_encode($diff, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
file_put_contents("$prefix.md", $md);

echo $md;
fwrite(STDERR, "\nWrote $prefix.json and $prefix.md\n");
