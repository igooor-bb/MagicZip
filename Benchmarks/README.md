# MagicZip benchmarks

Local macOS Release benchmarks using [ordo-one/benchmark](https://github.com/ordo-one/benchmark). The benchmark package uses this checkout and keeps its dependencies separate from the library.

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

Arguments are forwarded to the Benchmark CLI. Run `mise run benchmark -- help` to see its options. The task selects Release and configures the allocator installed by mise. No global `DYLD_*` configuration is needed. Tool and Swift dependency versions are pinned in `.mise.toml` and `Benchmarks/Package.resolved`.

Baselines, including histograms and sample counts, live under `Benchmarks/.benchmarkBaselines/` and are ignored by Git. Successful `baseline update` calls also save environment metadata under `Benchmarks/results/`: baseline name, date, Git commit and worktree diff fingerprint, Mac model, OS, Swift, allocator backend and installed conda package builds. Use names unique to a comparison, as updating an existing name replaces its baseline. Do not compare machines, Swift versions, allocator backends or fixture revisions as if they were library changes. Start a new baseline instead.

There are no CI jobs or regression thresholds. First compare two runs of the same checkout on an otherwise idle Mac to establish local variability. Use p50 for typical latency and read p90/p99 alongside the actual sample count and histogram, particularly when expensive AES/tree cases produce fewer samples. A baseline comparison is descriptive, not a pass/fail performance budget. `baseline check` is intentionally not configured.

## Workloads (fixture revision 1)

Each combination has a stable kebab-case name. `store`, `deflate`, `store-aes`, and `deflate-aes` use Store or Deflate level 6 with plaintext or AES-256. AES uses a fixed benchmark password and normal randomized salts.

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

Text contains numbered asset records. Random bytes and tree contents use a deterministic generator seeded with 42. Timestamps and AES salts may differ between runs; input content, paths, codec settings and archive sizes remain comparable. Default MagicZip limits are retained.

## Measurement boundaries and metrics

Every sample includes the complete public operation: archive opening, metadata work, CRC/HMAC verification, checked closure, and atomic publication where applicable. Read callbacks count bytes and pass chunks to `blackHole`. Catalog samples return owned metadata. Validation and release of that returned array occur after timing.

Preparation runs once per scenario, before warmup. Explicit `startMeasurement` / `stopMeasurement` exclude removal of the previous destination and validation. Writes always start with no destination, so replacement/cleanup is not measured. Every written archive is streamed back and compared byte-for-byte. Every extraction checks its exact path set and file contents. Read fixtures are fully compared during setup, and every read checks byte counts plus the library's integrity checks. Catalog names, sizes and count are checked after each sample. Errors fail the run. Scenario teardown removes its private `/private/tmp/magiczip-benchmark-*` directory, though abrupt termination can leave it behind.

Defaults: 3 warmup iterations, at most 100 samples or a 5-second runner duration budget per scenario. This is not a hard timeout, and setup, validation and cleanup add elapsed time. Setup, verification and warmup cache file data. Results measure warm-cache API performance, not cold-disk throughput or power-loss durability.

| Metric | Interpretation |
| --- | --- |
| `wallClock`, `cpuTotal` | Elapsed latency and process CPU time for one complete operation |
| `throughput` | Upstream's rounded integer operations/second (omitted when every sample rounds to zero) |
| `throughput-microops-per-second` | Operations/second × 1,000,000, preserving fractional throughput for slow AES cases |
| `payload-bytes-per-second` | Selected uncompressed bytes/second. Divide by 1,048,576 for MiB/s |
| `peakMemoryResident` | Sampled process RSS during the measured operation, including the runner and retained fixture metadata |
| `peakMemoryResidentDelta` | Sampled RSS increase relative to the start of the measurement. Warm allocator reuse can produce zero |
| `mallocCountTotal` | Allocator-reported allocation requests during the operation |
| `allocatedResidentMemory` (Swift 6.2) | jemalloc resident-byte growth between measurement boundaries, including allocator overhead, rather than cumulative allocated bytes |
| `mallocBytesCount` (Swift 6.3+) | Gross allocation bytes reported by Benchmark's malloc-interposer backend |
| `archive-bytes` (writes) | Final ZIP size including directory, ZIP64 and AES overhead |
| `archive-ratio-ppm` (writes) | ZIP bytes / input bytes × 1,000,000, integer-truncated. Divide by 10,000 for percent |

For catalog cases use operations/second or multiply by entry count for entries/second, not MiB/s. For selective extraction use only the selected bytes. The same source size makes throughput comparisons independent of ZIP size. Custom rates time the same complete operation. Prefer `throughput-microops-per-second` for slow cases. It remains available below 0.5 operations/second, where native integer throughput may be omitted.

`allocatedResidentMemory` on Swift 6.2 measures resident growth, while `mallocBytesCount` on Swift 6.3+ measures gross allocated bytes. These metrics are not interchangeable. Compare baselines using the same compiler and allocator backend. The task rejects environment flags that disable allocation statistics.

Allocator instrumentation changes allocation behavior. RSS is sampled, may miss short peaks, and can retain pages from setup or prior validation. Neither RSS metric is a leak detector or an iOS memory guarantee. Use the separate [streaming memory test](../Tests/README.md#streaming-memory-and-zip64) for the RSS budget check. Results here describe this Mac. They do not measure iPhone performance, SDK binary size, Secure APIs or async scheduling.

## Separate-process streaming comparisons

`StreamingProbe` measures wall time, peak RSS and allocator statistics in a fresh process for each sample. It is a separate Swift package with no Benchmark or allocator-instrumentation dependencies.

```sh
mise exec -- swift build -c release --package-path Benchmarks/StreamingProbe
python3 Benchmarks/StreamingProbe/compare.py /absolute/baseline/StreamingProbe \
  "$PWD/Benchmarks/StreamingProbe/.build/release/StreamingProbe"
```

Build both binaries in Release with the same toolchain. The driver prepares deterministic input, runs three alternating samples per workload, and prints CSV results. Each child has a 120-second timeout and a 512 MiB output-file limit. These measurements have no performance pass/fail threshold.

[Measurements from 2026-09-11](StreamingProbe/Measurements.md) preserve the earlier results and baseline setup. RSS-budget assertions belong to the [memory tests](../Tests/README.md#streaming-memory-and-zip64).
