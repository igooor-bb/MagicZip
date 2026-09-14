# Examples

Three standalone examples using the local MagicZip package. Run them on macOS 13+ with Xcode 26+ / Swift 6.2, from the repository root:

```sh
swift run --package-path Examples CreateAndExtract
swift run --package-path Examples PasswordProtectedArchive
swift run --package-path Examples SecureArchive
```

- [Create and extract](Sources/CreateAndExtract/CreateAndExtract.swift): create an archive from data and a folder, list entries, read a file and extract a selected folder.
- [Password-protected archive](Sources/PasswordProtectedArchive/PasswordProtectedArchive.swift): encrypt file contents with a shared password, read and extract asynchronously, and return data or metadata from a borrowed session.
- [Secure archive](Sources/SecureArchive/SecureArchive.swift): protect file contents, names and timestamps with `SecureZIPWriter`, then read and selectively extract with `SecureZIPReader`. This format uses the minizip-ng CDCD extension and requires a compatible reader. Entry count, compression methods and approximate sizes remain visible. See [Passwords and encryption](../Sources/MagicZip/MagicZip.docc/PasswordsAndEncryption.md) for compatibility details.

Each example prepares its own temporary files and removes them when finished. No input files or arguments are required.

To build and run all examples:

```sh
mise run validate-examples
```

This check is also part of `mise run check` and CI.
