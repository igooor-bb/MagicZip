# Tests

`MagicZipTests` covers archive reading and writing, encryption, malformed input, cancellation and failure cleanup. `CMinizipTestSupport` provides failure injection, and [Fixtures](MagicZipTests/Fixtures/README.md) contains independently generated archives.

Run the main suite from the repository root with `mise run test`. Use `mise run check` to include formatting and lint checks.

## Streaming memory and ZIP64

`StreamingMemoryTests` is a standalone executable that checks a 128 MiB peak RSS budget while writing and reading a 512 MiB Store entry. It also corrupts that entry and verifies that extracting a different entry succeeds. A budget or correctness failure makes the process exit unsuccessfully.

```sh
mise run test-memory
```

The test runs in a separate Release process so compiler memory and other tests do not affect its peak RSS. It is included in CI as a separate step. To also check a streamed entry larger than 4 GiB:

```sh
mise exec -- swift run -c release --package-path Tests/StreamingMemoryTests StreamingMemoryTests --zip64
```

This mode streams 5 GiB through Deflate and checks ZIP64 sizes on read. Both modes remove scratch output. They test a fixed payload-memory budget, not constant memory for arbitrary entry counts or names. Use [Benchmarks](../Benchmarks/README.md) for comparative measurements.

## Tree resource checks

```sh
mise run test-trees
```

This task builds first, then runs serial `TreeResourceTests` in a child process with a 120-second timeout, 128-descriptor limit and 128 MiB per-file limit. Run it through the task so these limits do not affect SwiftPM or other tests.

Cases include source depths 24/96/192, cleanup of a 300-level old destination, CRC and cancellation failures, 2,000 siblings, and sources overlapping output. Descriptor peaks are sampled and may miss brief transients. These resource-limited checks are separate from `mise run check` and normal CI.

For platform builds, CocoaPods clients and interoperability, see [Validation](../Validation/README.md).
