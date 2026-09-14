# Passwords and encryption

Encrypt file contents with one password, use per-entry passwords, or protect the catalog too.

MagicZip reads ZipCrypto and WinZIP AES-128/192/256 archives. New encrypted archives always use AES-256. ZipCrypto reading is provided for compatibility with older archives and does not provide modern cryptographic protection. Secure archives continue to require AES-256 for both the catalog and files.

## One password per archive

Pass `password:` to ``ZIPWriter`` to encrypt all regular files, including files added from directories and streams. Omit it or pass `nil` to write files without encryption. This applies equally to text and binary files. Explicit directory entries remain unencrypted. Passwords must contain 1...128 UTF-8 bytes without NUL.

```swift
try ZIPWriter.withArchive(at: archiveURL, password: "example-password") { writer in
    try writer.add(data: Data("Hello".utf8), path: "hello.txt")
}

try ZIPReader.withArchive(at: archiveURL) { reader in
    try reader.extract(to: outputURL, password: "example-password")
}
```

By design, ZIP's per-file encryption protects file contents, leaving names and other catalog metadata visible without a password. Catalog encryption is a separate feature ([APPNOTE, sections 4.1.4 and 7.1.6](https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT)). Read individual encrypted files by passing `password:` to `read` or `data`.

## Different passwords per entry

ZIP allows each file to use a different password, and encrypted and unencrypted files can coexist in one archive ([WinZip AES specification](https://www.winzip.com/en/support/aes-encryption/)). Use ``ZIPWriter/withMixedArchive(at:overwrite:body:)`` for this less common scenario. Its closure receives a ``MixedZIPWriter``. Use ``ZIPWriter`` when one password applies to all files.

``MixedZIPWriter`` requires an explicit `password:` on every file, tree or stream addition. Pass `nil` to leave those files unencrypted.

```swift
try ZIPWriter.withMixedArchive(at: archiveURL) { writer in
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

The synchronous, throwing password provider runs once per selected encrypted entry and never for unencrypted or unselected entries. Missing or incorrect passwords and provider errors roll back extraction before publication. Handle retries and password caching in your application. Do not reenter the reader from the provider, and treat entry metadata as untrusted input.

## Encrypted catalogs

``SecureZIPWriter`` and ``SecureZIPReader`` use minizip-ng's CDCD extension. Use them only when you control both ends or have a compatible reader. This is not PKWARE central-directory encryption. Compatibility with Finder and ordinary ZIP tools is not guaranteed.

```swift
try SecureZIPWriter.withArchive(at: archiveURL, password: "secret") { writer in
    try writer.add(data: contents, path: "private/report.txt")
}

try SecureZIPReader.withArchive(at: archiveURL, password: "secret") { reader in
    print(reader.entries.map(\.path))
    try reader.extract(to: outputURL)
}
```

One mandatory password protects the catalog and all regular files. The reader authenticates the catalog before invoking the body; file contents are authenticated when read. Ordinary `ZIPReader` rejects encrypted catalogs, and `SecureZIPReader` rejects ordinary archives and catalogs containing unencrypted regular files.

Original names, paths and timestamps are hidden. Entry count, file/directory boundaries, compression methods and approximate sizes remain observable. A password does not establish the author's identity. Catalog memory is capped at 64 MiB on both read and write, in addition to ordinary reader limits.

All password modes support `withArchiveAsync` and share the session, path-validation and publication rules described in <doc:StreamingAndOwnership> and <doc:SafetyAndLimits>.
