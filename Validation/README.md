# Validation

Run from the repository root with Xcode 26+ selected. mise pins Python, uv, Ruby,
SwiftFormat, clang-format and SwiftLint; `uv.lock` pins fixture packages and `Gemfile.lock`
pins CocoaPods/xcodeproj and transitive gems. No Python/Ruby dependency is needed by a
normal library build.

```sh
mise install
mise run setup
mise run check
mise run validate-apple
mise run validate-pods
mise run validate-compatibility
mise run validate-memory
```

`validate-apple` compiles the SPM library for macOS, iOS device and iOS Simulator, then
runs DocC with documentation warnings treated as errors. `validate-pods` generates
throwaway Xcode projects, uses `bundle exec` to install local specs, compiles real
Swift clients for all three destinations, runs the macOS client and lints the podspec
in static-library mode. Its Podfile uses SSZipArchive 2.5.5 (or `MAGICZIP_SSZIP_SOURCE`
for an already fetched checkout). The fixture/interoperability SPM package pins the
same version independently.

The only lint warnings explicitly allowed are nonfatal diagnostics: this checkout's
source/homepage may not yet be published, and upstream/SDK builds may emit warnings.
A compiler, linker, dependency-resolution or validation error still fails the command.
No validation task publishes pods, pushes commits, or uploads artifacts.

## Independent fixtures and interoperability

`Tests/MagicZipTests/Fixtures` contains independent Python zipfile, pyzipper and
SSZipArchive archives. The main Swift Testing suite never needs network access.
`Validation/Compatibility` links MagicZip and SSZipArchive in the same process, creates
plaintext/AES archives with each implementation and reads them with the other.

```sh
mise run fixtures-python
swift run --package-path Validation/Compatibility CompatibilityValidation Tests/MagicZipTests/Fixtures
```

Regeneration changes random AES salts. Review fixtures and refresh their SHA256 manifest.
Python tooling is isolated in `.venv`; Ruby dependencies in `.bundle/gems`; neither is
committed. Always use `uv run --locked --group fixtures` and `bundle exec` rather than
ambient Python packages or a system `pod` binary.

## Memory and selectivity

`Validation/StreamingProbe` streams a 512 MiB Store entry without allocating its full
contents, reads it back, corrupts the large payload, then extracts only a small second
entry. It asserts that no other file appears and reports the *executed process's*
peak RSS with `getrusage`, excluding compiler memory. The process budget is 128 MiB. To also verify a real entry beyond 4 GiB:

```sh
mise exec -- swift run -c release --package-path Validation/StreamingProbe StreamingProbe --zip64
```

This streams 5 GiB through Deflate and verifies the ZIP64 sizes on read; the compressed
scratch archive is much smaller. Both modes remove their scratch files afterward.
This measures bounded payload memory, not constant metadata memory for unlimited entries.

## Failure checks

Swift Testing covers independent formats, exact lookup and metadata lifetime, streaming,
selective extraction, traversal/aliases/symlinks, corrupt payloads and HMAC, truncation,
wrong passwords, limits, failure cleanup, overwrite and closed/reentrant sessions.
A test-only C stream injects failures precisely during Deflate and central-directory
finalization. A read-only descriptor substitution tests errors from the final file flush
without introducing a descriptor-reuse race between parallel tests.
