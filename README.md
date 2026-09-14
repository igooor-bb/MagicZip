# MagicZip

MagicZip is a modern Swift library for reading and creating ZIP archives, with a type-safe API, selective extraction, AES-256 encryption and async/await support.

*Uses [minizip-ng](https://github.com/zlib-ng/minizip-ng) as its ZIP engine.*

- **Requirements:** iOS 16+ or macOS 13+, with Xcode 26+ / Swift 6.2.
- **ZIP support:** Store and Deflate compression, UTF-8 names, and ZIP64.

## Installation

### Swift Package Manager

Add MagicZip to your package dependencies:

```swift
.package(url: "https://github.com/igooor-bb/MagicZip.git", from: "0.1.0")
```

Then add `.product(name: "MagicZip", package: "MagicZip")` to your target. Until a release tag is available, use a local checkout or a specific commit revision.

### CocoaPods

```ruby
pod 'MagicZip', '~> 0.1'
```

Both `MagicZip` and `MagicZipCMinizip` must be available in your spec repository. For a local checkout:

```ruby
pod 'MagicZip', :path => '/path/to/MagicZip'
pod 'MagicZipCMinizip', :path => '/path/to/MagicZip'
```

## Read and extract

Browse entries, read a file, or extract a folder:

```swift
import Foundation
import MagicZip

try ZIPReader.withArchive(at: archiveURL) { reader in
    for entry in reader.entries {
        print(entry.path)
    }

    let contents = try reader.data(path: "hello.txt")
    try reader.extract(to: outputURL, selection: .subtree("assets"))
}
```

Omit `selection` to extract the entire archive. For streaming large files, see [Streaming reads](Sources/MagicZip/MagicZip.docc/StreamingAndOwnership.md#streaming-reads).

## Create

Create an archive from data, files and folders:

```swift
try ZIPWriter.withArchive(at: archiveURL) { writer in
    try writer.add(data: Data("Hello".utf8), path: "hello.txt")
    try writer.add(file: sourceURL, path: "assets/source.bin")
    try writer.add(directory: folderURL, path: "documents")
}
```

Keep source files and folders unchanged until creation finishes. For password-protected archives, see [Passwords and encryption](Sources/MagicZip/MagicZip.docc/PasswordsAndEncryption.md).

## Async/await

```swift
let entries = try await ZIPReader.withArchiveAsync(at: archiveURL) { reader in
    try reader.extract(to: outputURL)
    return reader.entries
}
```

All reader and writer types provide `withArchiveAsync`. The closure runs synchronously on a background queue. Use the reader or writer only inside that closure. To use results afterward, return values such as `Data` or `[ZIPEntry]`, which conform to `Sendable`.

Cancelling the task requests a stop, but does not interrupt an active file operation or your callback. MagicZip checks for cancellation between processing steps. The `await` finishes only after the archive is closed and cleanup is complete.

## Behavior and limits

- Destination parents must already exist. File paths must contain no symlink components. Use actual paths such as `/private/tmp` instead of symlink aliases like `/tmp`.
- Existing destinations fail by default. Pass `overwrite: .replace` to replace a complete file or directory without merging directories. Failure before publication preserves the old destination. A cleanup error after publication can leave the new result visible.
- Traversal paths, conflicting names, symlinks and special files are rejected. Extraction does not restore permissions or timestamps.
- Reader defaults allow 100,000 entries, 1 GiB per entry and 4 GiB per selected operation, with additional path and expansion limits. Adjust `ZIPLimits` for your workload. `data` has a separate 16 MiB default cap.
- ZipCrypto, AES-128/192, legacy filename encodings, split archives and archive append are unsupported.

See [Safety and limits](Sources/MagicZip/MagicZip.docc/SafetyAndLimits.md) for the full contract and [Streaming and ownership](Sources/MagicZip/MagicZip.docc/StreamingAndOwnership.md) for streaming, cancellation and error handling. API reference documentation is available through Xcode's **Build Documentation** command.

## Development

With Xcode 26+ selected and mise installed:

```sh
mise trust
mise install
mise run check
```

Tool versions and tasks are defined in [.mise.toml](.mise.toml).

- [Tests](Tests/README.md): unit tests, memory budgets and resource checks.
- [Validation](Validation/README.md): platform builds, DocC, CocoaPods and compatibility.
- [Benchmarks](Benchmarks/README.md): local Release measurements and baseline comparisons.
- [Updating minizip-ng](Scripts/minizip/README.md): vendor updates and local patches.

## Contributing

Fork the repository, clone your fork, and create a branch for your change. Follow the setup steps in [Development](#development) and keep each pull request focused on one change.

Use the repository's formatters and run the checks before submitting:

```sh
mise run format          # Swift, C and Swift examples in Markdown
mise run format-markdown # Markdown layout
mise run check
```

Commit your changes, push the branch to your fork, and open a pull request. Describe what changed, why, and how you tested it. Include tests and documentation updates where relevant.

## License

MagicZip is licensed under [MIT](LICENSE). Vendored minizip-ng retains its zlib license. See [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
