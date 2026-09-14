# Updating minizip-ng

Run from the repository root on macOS after `mise install`. Git, curl and patch must also be available.

```sh
mise run update-minizip -- --ref 4.2.2
```

An exact upstream tag or full 40-character commit SHA is required. Normal Swift Package and CocoaPods builds use checked-in sources without downloading minizip-ng or running CMake.

## Import and review

The importer resolves the ref, downloads from official upstream, validates the archive and imports the reviewed source/header allowlist. It applies local patches and generates configuration and the `magiczip_` C symbol namespace before atomically replacing `Sources/CMinizip/vendor`. Failed preparation leaves the existing vendor directory unchanged.

[`METADATA.json`](../../Sources/CMinizip/vendor/METADATA.json) records the upstream URL, ref, resolved commit, archive SHA-256, configuration hash and ordered patch hashes. The hash records provenance, not an upstream signature.

After an update:

1. Review the allowlist, configuration and patches against upstream changes.
2. Run the import again and confirm that vendor files are unchanged.
3. Run `mise run check` and `mise run validate-apple`.
4. Run the CocoaPods and compatibility checks in [Validation](../../Validation/README.md), plus the memory and ZIP64 checks in [Tests](../../Tests/README.md). Compatibility validation also checks C symbol isolation.

## Local patches

Edit patches rather than generated vendor files. Every `.patch` must appear exactly once in [`patches/series`](patches/series), in application order. Patches apply with zero fuzz. New C identifiers are included in namespace generation.

| Patch | Purpose |
| --- | --- |
| `0001` | Integrate configuration and prefix upstream identifiers |
| `0002` | Propagate Deflate flush and ZIP entry-close failures |
| `0003` | Expose the computed CRC so the adapter can verify it without duplicate calculation |
| `0004` | Update replacement catalog bounds after CDCD decryption, fixing access to later entries |
| `0005` | Match the symlink buffer capacity type to `mz_os_read_symlink`, removing a narrowing warning |

The adapter retains size, CRC and AES authentication checks. Keep those checks intact when updating or retiring a patch.
