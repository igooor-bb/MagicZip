# ``MagicZip``

Read, create and selectively extract ZIP archives in Swift.

<!-- rumdl-disable MD013 -->

@Metadata {
    @Available(iOS, introduced: "16.0")
    @Available(macOS, introduced: "13.0")
    @Available(Swift, introduced: "6.2")
    @Available(Xcode, introduced: "26.0")
}

<!-- rumdl-enable MD013 -->

## Overview

Read and write Store or Deflate archives, stream large files, and protect file contents with AES-256.

```swift
import Foundation
import MagicZip

func example(archive: URL, destination: URL) throws {
    try ZIPWriter.withArchive(at: archive, password: "example-password") { writer in
        try writer.addDirectory(path: "documents")
        try writer.add(
            data: Data("Hello".utf8),
            path: "documents/hello.txt",
            compression: .deflate(level: 6),
        )
    }
    try ZIPReader.withArchive(at: archive) { reader in
        let entry = reader.entry(at: "documents/hello.txt")
        print(entry?.uncompressedSize ?? 0)
        try reader.extract(
            to: destination,
            selection: .subtree("documents"),
            password: "example-password",
        )
    }
}
```

Use a parent directory that already exists. File URLs must contain no symlink components, including system aliases such as `/tmp` and `/var`. Supply the actual path (for example `/private/tmp`) when appropriate. Entry paths are always relative UTF-8 ZIP paths with `/` separators. Neither extraction nor archive creation follows symlinks.

## Topics

### Reading

- ``ZIPReader``
- ``ZIPEntry``
- ``ZIPSelection``
- ``ZIPLimits``

### Writing

- ``ZIPWriter``
- ``MixedZIPWriter``

### Encryption

- ``SecureZIPWriter``
- ``SecureZIPReader``
- <doc:PasswordsAndEncryption>

### Options

- ``ZIPCompression``
- ``ZIPEncryption``
- ``ZIPOverwrite``

### Asynchronous sessions

- ``ZIPReader/withArchiveAsync(at:limits:body:)``
- ``ZIPWriter/withArchiveAsync(at:password:overwrite:body:)``
- ``ZIPWriter/withMixedArchiveAsync(at:overwrite:body:)``

### Failure handling and ownership

- ``ZIPError``
- ``ZIPBackendOperation``
- ``ZIPBackendStatus``
- <doc:StreamingAndOwnership>
- <doc:SafetyAndLimits>
