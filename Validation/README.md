# Validation

This directory contains standalone clients for checking MagicZip integration through Swift Package Manager and CocoaPods, and compatibility with other ZIP implementations.

Use these checks when changing packaging or the ZIP backend. They complement the [tests](../Tests/README.md) and are not included in the library distributed to users. Resource-budget checks live in `Tests`, while performance measurements live in [Benchmarks](../Benchmarks/README.md).

Run checks from the repository root with Xcode 26+ selected. Install pinned tools and fixture/CocoaPods dependencies first:

```sh
mise install
mise run setup
```

## Checks

| Command | Coverage |
| --- | --- |
| `mise run check` | Swift/C formatting, SwiftLint, Markdown lint and Swift Testing |
| `mise run validate-apple` | Swift Package builds for macOS, iOS and Simulator, plus DocC with warnings treated as errors |
| `mise run validate-pods` | Real CocoaPods clients for all three destinations, macOS execution and podspec lint |
| `mise run validate-compatibility` | Plaintext/AES interoperability with SSZipArchive and C symbol isolation |

The normal test suite uses checked-in fixtures and needs no network access. CocoaPods and compatibility validation may download dependencies. CocoaPods validation allows nonfatal warnings, but compilation, linking, dependency-resolution and validation errors still fail the command.

## Fixtures and interoperability

[Independent fixtures](../Tests/MagicZipTests/Fixtures/README.md) come from Python zipfile, pyzipper and SSZipArchive. The compatibility client links MagicZip and SSZipArchive in the same process and reads archives written by each implementation.

To regenerate fixtures:

```sh
mise run fixtures-python
swift run --package-path Validation/Compatibility CompatibilityValidation Tests/MagicZipTests/Fixtures
```

AES salts are random, so regeneration changes archive bytes. Review the output and refresh `Tests/MagicZipTests/Fixtures/SHA256.json`. Use the locked tools through mise, `uv run --locked --group fixtures` and `bundle exec`. Avoid ambient Python packages or a system `pod` binary.

Tests cover malformed paths and metadata, unsupported formats, wrong passwords, corrupt CRC/HMAC, size limits, cancellation, finalization failures, overwrite behavior and cleanup. Password tests include mixed encrypted/plaintext selection and throwing providers. Secure catalog tests use independently generated CDCD fixtures. Finder compatibility is not tested.

## Formatting

Use `mise run format` for owned Swift/C code and Swift examples in Markdown. Both Swift sources and examples follow `.swiftformat`, and `mise run format-check` checks both. Use `mise run format-markdown` for Markdown layout. Rules and versions live in `.swiftformat`, `.swiftlint.yml`, `.rumdl.toml` and `.mise.toml`. Vendored sources are excluded. Keep each Markdown paragraph on one source line and let GitHub handle visual wrapping.
