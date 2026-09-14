# Updating minizip-ng

From the repository root on macOS, with Python 3, Git, curl and patch installed:

```sh
mise run update-minizip -- --ref 4.2.2
# A full, 40-character upstream commit SHA is also accepted.
```

Only this maintenance command downloads sources. Normal Swift Package and CocoaPods builds compile the checked-in sources without network access or CMake.

The importer resolves exact tags (including annotated tags) to commits, downloads from the official GitHub codeload endpoint, checks the entire archive structure, selects the explicit Apple source/header allowlist, retains LICENSE and creates the configuration and symbol namespace header. `METADATA.json` records the URL, ref, commit, archive SHA-256, configuration hash and ordered patch hashes. The hash records provenance; it is not an independently authenticated upstream signature.

`patches/series` specifies the application order, top to bottom. Every `.patch` must appear exactly once. Add a numbered patch there when modifying upstream code; never edit `vendor/` manually. Patches apply with zero fuzz. `0001` integrates configuration and prefixes upstream identifiers. `0002` propagates Deflate flush and ZIP entry-close errors that upstream drops. The adapter separately verifies CRC, size and AES HMAC.

Preparation is isolated under `Sources/CMinizip/.import-*`. An advisory lock serializes updates; a Darwin atomic rename/swap publishes only complete results. Interrupted or failed preparation leaves `vendor/` unchanged. No unrelated paths are replaced. Run the command twice and compare file hashes/diffs before committing an update. There are no timestamps or machine-specific paths in generated metadata.

After an upstream upgrade, review the allowlist, configuration and patches, run `mise run check`, `mise run validate-apple` and the interoperability/large-archive checks described in the repository documentation. In particular, audit global C symbols: Clang module names alone cannot prevent link collisions with other ZIP implementations.

`0003-expose-computed-crc.patch` exposes the running, actually computed entry CRC to the private adapter. It does not replace the adapter's checksum comparison, size validation or HMAC checks with upstream's conditional close verification. Namespace generation follows patch application so newly introduced identifiers receive the same `magiczip_` prefix.

`0004-update-replaced-catalog-bounds.patch` updates `cd_size` when installing a replacement central-directory stream. Upstream retained the small outer directory's size after CDCD decryption, so random access into later inner records failed. The adapter implements CDCD framing using the existing low-level API, with checked closure/HMAC, a 64 MiB catalog budget and Swift cancellation checkpoints; the upstream high-level `mz_zip_rw` layer is intentionally not imported.

`0005-match-symlink-buffer-capacity-type.patch` declares the fixed 1024-byte symlink read buffer capacity as `const int32_t`, matching `mz_os_read_symlink`. This removes the implicit `size_t` narrowing warning without suppressing diagnostics or changing the allocation size or runtime behavior.
