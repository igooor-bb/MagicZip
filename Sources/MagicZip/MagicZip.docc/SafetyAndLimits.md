# Safety and limits

Extract only valid entry paths and publish complete results.

## Filesystem contract

Extraction creates a private sibling directory with mode 0700. Files use mode 0600.
Operations are anchored to open directory descriptors using `openat`, `mkdirat`,
`O_NOFOLLOW` and exclusive creation. A renamed ancestor cannot redirect writes into
another path. Cleanup does not follow symlinks, including symlinks in replaced directories.
The destination parent must exist; its symlink components are rejected.

``ZIPOverwrite/fail`` is the default. ``ZIPOverwrite/replace`` atomically swaps a complete
file/directory of the same type, then removes the old result. Existing directories are
replaced wholesale, never merged. Before publication, failure or cancellation preserves
the old destination and cleans staging output. After a successful swap, a cleanup error
is reported but the new destination is already visible. Atomic visibility does not promise
power-loss durability; a killed process can leave a `.magiczip-*` staging directory.

The caller must control the source tree during creation. As with other filesystem APIs,
this is not a security boundary against another process running with the same user identity
and permission to modify open staging directories or mounts.

## Path validation

Absolute paths, drive prefixes, NUL, backslashes, empty components, `.` and `..` are rejected.
Individual path components are limited to 255 UTF-8 bytes. ZIP names are limited to 65,535
bytes. File/directory prefix conflicts, duplicates, case aliases and canonical Unicode
aliases are rejected conservatively on all supported filesystems, even case-sensitive ones.
Symlinks, devices, sockets and other nonregular Unix entries are unsupported.

The entire metadata table is validated when opening, even for selective extraction.
Only selected payloads are opened or decompressed. Subtree selection respects component
boundaries and keeps original archive paths. Missing exact selections fail before publication.

## Supported formats

- Store and Deflate; writing accepts Deflate levels 0...9 (zero maps to Store).
- Plaintext and WinZIP AES-256: AE-1/AE-2 reading, AE-2 writing.
- UTF-8 names (ASCII is accepted without the UTF-8 flag), empty files/directories and ZIP64.

Unsupported compression/encryption can be listed but fails when selected for reading.
Legacy filename encodings, traditional ZipCrypto, AES-128/192, split archives, symlinks,
archive append/in-place modification and arbitrary metadata restoration are unsupported.
Directories are not encrypted. Passwords are not included in library diagnostics; the API
does not promise secure erasure of Swift strings or callback-provided data.

CRC and HMAC verify selected payloads. Central-directory metadata is not cryptographically
authenticated by the ZIP AES format. Apply ``ZIPLimits`` appropriate to the application and
never trust sizes, names or compressed data from an untrusted producer without verification.
