# MagicZip benchmarks

Local macOS Release benchmarks using [ordo-one/benchmark 1.36.0](https://github.com/ordo-one/benchmark/releases/tag/1.36.0).
The nested Swift package depends on the checkout above it. Benchmark and its allocator dependencies do not enter
the MagicZip consumer dependency graph. Public library APIs and the independent `Validation` checks are unchanged.

## Run and compare

Install Xcode 26+ / Swift 6.2+, then run from the repository root:

```sh
mise install
mise run benchmark -- list
mise run benchmark -- run
mise run benchmark -- run --filter 'read-.*-aes'
mise run benchmark -- baseline update before
# Make the library change, keeping the workload and toolchain identical.
mise run benchmark -- baseline update after
mise run benchmark -- baseline compare before after
```

Arguments are forwarded to the official CLI; `mise run benchmark -- help` lists its options. The wrapper selects
Release, permits local baseline writes, and configures the allocator library search path. `conda:jemalloc@5.3.0`
is installed by mise's built-in conda backend; no Homebrew, Conda executable or global `DYLD_*` configuration is needed.
The small header adapter in `Support` maps Benchmark's four unprefixed statistics calls to conda-forge's `je_*` API;
it does not replace allocation functions or modify the upstream packages.
The package's `Package.resolved` locks Swift dependencies. The conda version is pinned; record its installed build
metadata with each baseline, since conda may publish multiple builds of one version.

Baselines, including histograms and sample counts, live under `Benchmarks/.benchmarkBaselines/` and are ignored by Git.
Successful `baseline update` calls also save environment metadata under `Benchmarks/results/`: baseline name, date,
Git commit and worktree diff fingerprint, Mac model, OS, Swift, allocator backend and installed conda package builds.
Use names unique to a comparison; updating an existing name replaces its baseline. Do not compare machines, Swift
versions, allocator backends or fixture revisions as if they were library changes. Start a new baseline instead.

There are no CI jobs or regression thresholds. First compare two runs of the same checkout on an otherwise idle Mac
to establish local variability. p50 is useful for typical latency; use p90/p99 together with actual sample count and
the histogram, particularly when expensive AES/tree cases produce fewer samples. A baseline comparison is descriptive,
not a pass/fail performance budget. `baseline check` is intentionally not configured.

## Workloads (fixture revision 1)

Each combination has a stable kebab-case name. `store`, `deflate`, `store-aes`, and `deflate-aes` use Store or Deflate
level 6 with plaintext or AES-256. AES uses a fixed benchmark password and normal randomized salts.

| Names | Input / operation | Count |
| --- | --- | ---: |
| `write-{text,random}-{variant}` | File-backed write of 64 MiB | 8 |
| `read-{text,random}-{variant}` | 64 KiB streaming callbacks over 64 MiB | 8 |
| `extract-all-{text,random}-{variant}` | Extract the complete 64 MiB file | 8 |
| `write-tree-{variant}` | Directory write: 20 directories × 100 files × 1 KiB | 4 |
| `extract-all-tree-{variant}` | Extract all 2,000 files (2,048,000 bytes) | 4 |
| `extract-path-tree-{variant}` | `.paths`: extract `tree/d00/f000.bin` (1,024 bytes) | 4 |
| `extract-subtree-tree-{variant}` | `.subtree`: extract `tree/d00` (102,400 bytes) | 4 |
| `catalog-{1000,10000}-store` | Open, return metadata for empty entries, close | 2 |

Text contains numbered asset records; random bytes use SplitMix64 seeded with 42 and explicit little-endian output.
The tree uses the same generator for file content. Generation writes bounded chunks; no 64 MiB `Data` or committed
binary fixture is needed. File metadata is not required to be byte-identical: timestamps and AES salts may differ;
input content, paths, codec settings and archive sizes remain comparable. Default MagicZip limits are retained.

## Measurement boundaries and metrics

Every sample includes the complete public operation: archive opening, metadata work, CRC/HMAC verification, checked
closure, and atomic publication where applicable. Read callbacks count bytes and pass chunks to `blackHole`.
Catalog samples return owned metadata; validation and release of that returned array occur after timing.

Preparation runs once per scenario, before warmup. Explicit `startMeasurement` / `stopMeasurement` exclude removal
of the previous destination and validation. Writes always start with no destination, so replacement/cleanup is not
measured. Every written archive is streamed back and compared byte-for-byte; every extraction checks its exact path
set and file contents. Read fixtures are fully compared during setup, and every read checks byte counts plus the
library's integrity checks. Catalog names, sizes and count are checked after each sample. Errors fail the run.
Scenario teardown removes its private `/private/tmp/magiczip-benchmark-*` directory; abrupt termination can leave it.

Defaults: 3 warmup iterations, at most 100 samples or a 5-second runner duration budget per scenario. This is not a
hard timeout, and setup, validation and cleanup add elapsed time. File data is cached by setup/verification/warmup;
these are warm-cache API measurements, not cold-disk throughput or power-loss durability measurements.

| Metric | Interpretation |
| --- | --- |
| `wallClock`, `cpuTotal` | Elapsed latency and process CPU time for one complete operation |
| `throughput` | Upstream's rounded integer operations/second; omitted by Benchmark when every sample rounds to zero |
| `throughput-microops-per-second` | Operations/second × 1,000,000; preserves fractional throughput for slow AES cases |
| `payload-bytes-per-second` | Processed uncompressed bytes/second; divide by 1,048,576 for MiB/s; excludes unselected files |
| `peakMemoryResident` | Sampled process RSS during the measured operation, including the runner and retained fixture metadata |
| `peakMemoryResidentDelta` | Sampled RSS increase relative to the start of the measurement; warm allocator reuse can produce zero |
| `mallocCountTotal` | Allocator-reported allocation requests during the operation |
| `allocatedResidentMemory` (Swift 6.2) | jemalloc resident-byte growth between measurement boundaries, including allocator overhead; not cumulative allocated bytes |
| `mallocBytesCount` (Swift 6.3+) | Gross allocation bytes reported by Benchmark's malloc-interposer backend |
| `archive-bytes` (writes) | Final ZIP size including directory, ZIP64 and AES overhead |
| `archive-ratio-ppm` (writes) | ZIP bytes / input bytes × 1,000,000, integer-truncated; divide by 10,000 for percent |

For catalog cases use operations/second or multiply by entry count for entries/second, not MiB/s. For selective
extraction use only the selected bytes. The same source size makes throughput comparisons independent of ZIP size.
The two custom rates use `ContinuousClock` around the same complete operation, inside Benchmark's measurement
boundaries. The native timing includes these two clock reads; custom-rate calculation occurs after timing.
Use the custom operation rate for comparisons: unlike upstream's integer throughput it remains available below
0.5 operations/second. A missing native throughput histogram in a slow case is not a missing custom-rate measurement.

**Compatibility correction to the initial plan:** Benchmark 1.36.0's Swift 6.2 jemalloc backend does not populate
`mallocBytesCount`. The suite explicitly requests `allocatedResidentMemory` instead on that compiler; it is a
different metric, not a substitute value presented under the original name. The full original metric list requires
Swift 6.3+ and its malloc-interposer backend. The wrapper rejects environment flags disabling allocation statistics.

Allocator instrumentation changes allocation behavior. RSS is sampled, may miss short peaks, and can retain pages
from setup or prior validation. Neither RSS metric is a leak detector or an iOS memory guarantee. Keep using the
separate-process streaming memory validation for its budget check. Results here describe this Mac; they do not
measure iPhone performance, SDK binary size, Secure APIs or async scheduling.
