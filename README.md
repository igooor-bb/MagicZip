# MagicZip

A Swift library for reading and creating ZIP archives over vendored minizip-ng 4.2.2.
Supports **iOS 16+, iOS Simulator and macOS 13+**, with **Xcode 26.0+ / Swift tools 6.2**.
The public product/module is `MagicZip`. No experimental Swift flags or external runtime
dependencies: Apple builds use system zlib, CommonCrypto and Security.

## Installation

### Swift Package (primary)

```swift
.package(url: "https://github.com/igooor-bb/MagicZip.git", from: "0.1.0")
```

Add `.product(name: "MagicZip", package: "MagicZip")` to your target. Until a release tag
is published, use a local package checkout or an explicitly chosen commit revision.

### CocoaPods

```ruby
pod 'MagicZip', '~> 0.1'
```

The pod depends on the companion implementation spec `MagicZipCMinizip`, whose Clang
module is `CMinizip`. Both specs must be available in your spec repository. Nothing is
published by this checkout. For local development, use both paths:

```ruby
pod 'MagicZip', :path => '/path/to/MagicZip'
pod 'MagicZipCMinizip', :path => '/path/to/MagicZip'
```

SPM and CocoaPods compile the same Swift, C, configuration and patched vendor files.
The separate C target avoids mixed-language target workarounds. Consumers use:

```swift
import MagicZip
```

## Read and extract

```swift
try ZIPReader.withArchive(at: archiveURL) { reader in
    for entry in reader.entries {
        print(entry.path, entry.uncompressedSize, entry.encryption)
    }
    let metadata = reader.entry(at: "assets/logo.png")
    let smallFile = try reader.data(path: "notes.txt", maximumBytes: 1024 * 1024)
    try reader.read(path: "video.mov") { chunk in
        // Consume owned Data synchronously. Success is confirmed only after the final integrity check.
        consume(chunk)
    }
    try reader.extract(to: outputURL, selection: .subtree("assets"))
}
```

Use `.all` (the default) or `.paths(["notes.txt", "empty/"])` for other selections.
Unselected payloads are never opened. Copied metadata remains valid after the scope closes.
Add `password:` when reading AES entries. Optional password failures never expose credentials
in library-generated errors.

## Create

```swift
try ZIPWriter.withArchive(at: archiveURL, password: "example-password", overwrite: .replace) { writer in
    try writer.add(data: Data("Hello".utf8), path: "hello.txt", compression: .store)
    try writer.add(file: sourceURL, path: "assets/source.bin",
                   compression: .deflate(level: 9))
    try writer.addDirectory(path: "empty")
    try writer.add(directory: folderURL, path: "folder")
}
```

For a producer-backed stream, use `addStream(path:compression:modificationDate:producer:)`.
The producer receives a maximum chunk size of 64 KiB and returns a nonempty `Data` no larger
than requested, or `nil` at EOF. Source files/directories must remain stable during reading.
Creation uses ZIP64 for entries of unknown final size, including small streamed files.

## Async/await

Use `withArchiveAsync` to suspend the caller while a complete archive session runs on a
background work queue. Existing synchronous APIs remain available.

```swift
try await ZIPWriter.withArchiveAsync(at: archiveURL, password: "example-password") { writer in
    try writer.add(file: sourceURL, path: "assets/source.bin")
}
let entries = try await ZIPReader.withArchiveAsync(at: archiveURL, password: "example-password") { reader in
    try reader.extract(to: outputURL, selection: .subtree("assets"), password: "example-password")
    return reader.entries
}
```

Bodies are synchronous `@Sendable` closures; capture immutable URLs/data/options and return
owned `Sendable` values. Readers/writers stay inside their scope. Streaming callbacks still
consume/produce bounded chunks synchronously; async producers and `AsyncSequence` are not
provided. Do not access main-actor state from the body or synchronously wait for another
async archive operation. Task-local values and task identity do not propagate into the body.

A shared queue runs at most two async sessions at once. Cancellation is forwarded explicitly
to archive checkpoints, including before publishing each result. Await waits for finalization
and cleanup, even when cancelled. A cancelled queued job skips its body when a worker becomes
available; native calls and user callbacks cannot be interrupted. Cancellation racing with or
following publication does not undo the result and may still return success. Arbitrary body
code must finish or throw before cancellation can be observed by the next archive operation.

## Ownership, limits and publication

- Reader/writer sessions own one handle, are synchronous and non-`Sendable`, and reject
  concurrent/reentrant use. An internal `~Copyable` owner prevents handle copies. Successful
  scopes explicitly check entry/archive finalization. A failed add invalidates the writer.
  Descriptor transfer uses `consuming` and `discard self`; filesystem helpers use `borrowing`.
- Streaming payload memory is bounded. Metadata grows with entries/name bytes and has finite
  budgets. Defaults: 100,000 entries, 16 MiB names, 1 GiB per entry, 4 GiB per selected operation,
  maximum expansion ratio 1,000. Customize `ZIPLimits`; `data` has a separate 16 MiB default cap.
- Files/trees are staged privately beside the destination. Default overwrite policy is `.fail`;
  `.replace` atomically replaces a complete destination of the same type without merging.
  Failure before publication removes staging output and preserves the old destination.
  Cleanup failure after publication is reported, with the new result already visible.
- Task cancellation is checked between chunks; callbacks can throw. CRC-32, sizes and AES HMAC
  are checked before successful completion. Streamed chunks remain provisional until then.
- Destination parents must exist and contain no symlink components. This intentionally rejects
  system aliases such as `/tmp` and `/var`; use their actual paths, e.g. `/private/tmp`.
  Foundation's `resolvingSymlinksInPath()` may retain these aliases on macOS.
- Traversal, absolute/ambiguous names, duplicates, case/Unicode aliases, file/directory conflicts,
  symlinks and special files are rejected. Writes/cleanup are descriptor-relative and do not
  follow symlinks. Permissions and timestamps are not restored during extraction.

Supported: Store/Deflate, plaintext/WinZIP AES-256, UTF-8, empty entries, ZIP64. Unsupported:
ZipCrypto, AES-128/192, legacy filename encodings, split archives, other compression methods,
in-place modification/append, custom containers and MagicBox/BundleSupport integration.
Unsupported codecs/encryption can be listed but throw when selected. No secure-erasure or
power-loss durability guarantee; abrupt process termination may leave a staging directory.

## Development

Infrastructure follows [Wift](https://github.com/igooor-bb/wift): pinned mise tools and identical
local/CI tasks. Install mise and Xcode 26+, then:

```sh
mise trust
mise install
mise run setup        # locked Python fixture tools and CocoaPods/xcodeproj
mise run format       # SwiftFormat + clang-format, owned code only
mise run format-check # checks both Swift and C
mise run lint         # SwiftLint
mise run test         # Swift Testing
mise run check        # format-check, lint, test
mise run validate-apple
mise run validate-pods
```

SwiftFormat 0.62.1, SwiftLint 0.65.1, clang-format 22.1.8, Python 3.14.7, uv 0.12.11 and Ruby 3.4.10 are pinned.
`uv.lock` fixes Python fixture dependencies; `Gemfile.lock` fixes CocoaPods/xcodeproj and transitive gems.
Use `uv run --locked --group fixtures` and `bundle exec` through the mise tasks. Vendored code is excluded
from formatting/linting. Apple validation builds macOS, iOS device and Simulator plus DocC.
See [the completed validation report](Validation/RESULTS.md) and [Validation](Validation/README.md) for real CocoaPods clients, independent ZIP
compatibility, RSS measurements and fixture regeneration. Public declarations have DocC
comments and the catalog lives in `Sources/MagicZip/MagicZip.docc`.

## Updating minizip-ng

```sh
./Scripts/update-minizip.sh --ref 4.2.2
```

The first vendoring was performed with this same script. It accepts exact tags/full commits,
resolves tags, downloads from official upstream, validates the archive, selects reviewed files
and atomically replaces only the vendor directory. Ordinary builds never download or run CMake.

Current provenance is in [`METADATA.json`](Sources/CMinizip/vendor/METADATA.json): upstream URL,
ref, resolved commit, archive SHA-256 and configuration/ordered patch hashes. Local patches are
in [`Scripts/minizip/patches`](Scripts/minizip/patches), applied in explicit `series` order.
See [the importer guide](Scripts/minizip/README.md). Repeat the import and verify no diff.

C symbol isolation is generated for all upstream `mz_*` identifiers, including globals, using
`magiczip_` names. The compatibility API is not compiled. A Clang module name alone would not
prevent collisions; private validation links an independent ZIP implementation in the same process.

## License

MagicZip-owned code is MIT licensed; see [LICENSE](LICENSE). Vendored minizip-ng retains its
zlib license and original source notices. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).

### Path and source budgets

Reader defaults include `maximumPathDepth: 256` and `maximumPathNodes: 100_000` in `ZIPLimits`.
Depth includes the final name; implicit directories consume nodes. Writers use the same finite
budgets, 100,000 entries and 16 MiB of names. The registry stores parent IDs and individual
components: expected linear work in name bytes and linear storage, without recursive teardown.

Directory creation and cleanup are iterative, with descriptor usage independent of depth.
Source names are sorted once per directory and globally bounded; cleanup removes batches of
256 names per level and has no archive depth limit. Reopening components from the pinned root
costs O(sum of visited depths) filesystem operations while preserving symlink protection.
Source cancellation is checked during traversal; cleanup still attempts to finish.

Archive creation rejects sources overlapping its staging directory, open output or previous
destination by device/inode, including aliases. A destination inside the source tree fails
without replacing the old result. Ordinary `.magiczip-user` directories remain valid sources.
Directory subtree selection accepts explicit names with or without a trailing slash and keeps
UTF-8 spelling exact. Scan and close failures are combined rather than losing the close error.

File input uses one noncopyable 64 KiB buffer; reading reuses a Swift-managed byte array.
Both borrow bytes across internal file/C boundaries; public callbacks still receive independent
owned `Data`. CRC, AES
HMAC and size checks remain enabled. See [validation](Validation/README.md) for reproducible
performance measurements and the separate resource-limited tree checks.

### Password APIs

`ZIPWriter.withArchive(at:password:overwrite:body:)` sets one optional password for
all regular files, including files added through trees and producers. Its `add`
methods do not accept passwords. `nil` creates plaintext files. Explicit directory
entries remain unencrypted. Passwords are validated before the writer body runs.

Use `MixedZIPWriter` when entries intentionally have different passwords. Each
`add` / `addStream` requires an explicit `password:`; pass `nil` for plaintext.
Both writer types have `withArchiveAsync` and share the same transaction, limits,
exclusive handle ownership and failure cleanup.

```swift
try MixedZIPWriter.withArchive(at: archiveURL) { writer in
    try writer.add(data: first, path: "first.txt", password: "first-password")
    try writer.add(data: second, path: "second.txt", password: "second-password")
    try writer.add(data: readme, path: "README.txt", password: nil)
}
try ZIPReader.withArchive(at: archiveURL) { reader in
    try reader.extract(to: outputURL) { entry in
        passwordsByPath[entry.path]
    }
}
```

`extract(to:selection:overwrite:passwordProvider:)` invokes its synchronous throwing
provider once per selected encrypted entry, never for plaintext or unselected entries.
A missing/wrong password or provider error rolls back extraction. Password retries and
caching are the caller's responsibility. Do not reenter the reader from the provider.
Names and other ZIP metadata are visible without a password and are untrusted input.
The single-password extraction overload delegates to this same implementation.

Migration: move `password:` from ordinary writer additions to `withArchive` (or
`withArchiveAsync`), or explicitly choose `MixedZIPWriter` and specify passwords
on every addition. Scoped lifetimes and atomic publication are unchanged.
