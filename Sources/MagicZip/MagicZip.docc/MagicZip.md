# ``MagicZip``

Read and create ZIP archives with bounded streaming and transactional extraction.

## Overview

MagicZip supports iOS 16+, iOS Simulator and macOS 13+, using Swift 6.2 in Xcode 26 or
newer. It wraps an isolated minizip-ng C target and exposes only Swift values and scoped
sessions. Normal builds require no network access, CMake, or third-party runtime libraries.

```swift
import Foundation
import MagicZip

func example(archive: URL, destination: URL) throws {
    try ZIPWriter.withArchive(at: archive) { writer in
        try writer.addDirectory(path: "documents")
        try writer.add(data: Data("Hello".utf8), path: "documents/hello.txt",
                       compression: .deflate(level: 6), password: "example-password")
    }
    try ZIPReader.withArchive(at: archive) { reader in
        let entry = reader.entry(at: "documents/hello.txt")
        print(entry?.uncompressedSize ?? 0)
        try reader.extract(to: destination, selection: .subtree("documents"),
                           password: "example-password")
    }
}
```

Use a parent directory that already exists. File URLs must contain no symlink components;
this includes system aliases such as `/tmp` and `/var`. Supply the actual path (for example
`/private/tmp`) when appropriate. Entry paths are always relative UTF-8 ZIP paths with `/`
separators. Neither extraction nor archive creation follows symlinks.

## Topics

### Reading

- ``ZIPReader``
- ``ZIPEntry``
- ``ZIPSelection``
- ``ZIPLimits``

### Writing

- ``ZIPWriter``
- ``ZIPCompression``
- ``ZIPEncryption``
- ``ZIPOverwrite``

### Failure handling and ownership

- ``ZIPError``
- <doc:StreamingAndOwnership>
- <doc:SafetyAndLimits>
