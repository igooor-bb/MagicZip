# Safety and limits

Choose resource limits and understand when output becomes visible.

## Filesystem behavior

Destination parents must already exist. Source and destination paths must contain no symlink components, including system aliases such as `/tmp` and `/var`. Use the actual path, such as `/private/tmp`. Foundation's `resolvingSymlinksInPath()` may retain these aliases on macOS.

``ZIPOverwrite/fail`` is the default. ``ZIPOverwrite/replace`` atomically replaces a complete file or directory of the same type. Directories are never merged. Output is staged privately beside the destination. Failure or cancellation before publication preserves the old destination and attempts to remove staging output. If cleanup fails after publication, the operation throws but the new result is already visible.

Extracted files use mode 0600 and directories use mode 0700. Original permissions and timestamps are not restored. Writes and cleanup do not follow symlinks. Atomic visibility does not guarantee power-loss durability. Abrupt process termination can leave a `.magiczip-*` staging directory.

Keep source files and directories unchanged during creation. Sources overlapping the output, including hard links or a destination inside the source tree, are rejected. These protections do not isolate operations from another process running as the same user with permission to modify staging directories or mounts.

## Entry paths and selection

Entry paths are relative UTF-8 paths with `/` separators. Absolute paths, drive prefixes, NUL, backslashes, empty components, `.` and `..` are rejected. Components are limited to 255 UTF-8 bytes and complete ZIP names to 65,535 bytes.

Duplicates, case aliases, canonical Unicode aliases and file/directory conflicts are rejected, including on case-sensitive filesystems. Symlinks, devices, sockets and other special entries are unsupported.

All metadata is validated when opening an archive; only selected payloads are decompressed. Exact selections use the original UTF-8 spelling and fail if a path is missing. Subtree selection preserves archive paths and respects component boundaries: `assets` includes `assets/logo.png`, but not `assets-old/logo.png`. A directory can be selected with or without its trailing slash. An ordinary file is not a subtree.

## Resource limits

``ZIPLimits`` controls reader metadata and decompression budgets:

| Limit | Default |
| --- | --- |
| Entries | 100,000 |
| Total entry-name bytes | 16 MiB |
| Components per path | 256 |
| Distinct path nodes | 100,000 |
| Uncompressed bytes per entry | 1 GiB |
| Uncompressed bytes per selected operation | 4 GiB |
| Expansion ratio | 1,000 |

The final name counts toward path depth, and implicit parent directories consume path nodes. Writers use the same fixed entry-count, name-byte, depth and node budgets. `data` has an additional 16 MiB default cap, adjustable with `maximumBytes`. Secure catalogs have a separate fixed 64 MiB allocation budget.

Reader limits apply to advertised and actual output. These are application budgets, not ZIP64 format limits. Choose values appropriate to your workload. Limit violations throw ``ZIPError/limitExceeded(_:)``. Streaming bounds payload memory, while metadata still grows with archive size. Deep trees can take longer to traverse even within these limits.

## Format support

- Store and Deflate (levels 1...9 for writing).
- Plaintext and WinZIP AES-256: AE-1/AE-2 reading and AE-2 writing.
- UTF-8 names, ASCII without the UTF-8 flag, empty files/directories and ZIP64.

Unsupported compression and encryption can be listed, but fail when selected for reading. Legacy filename encodings, ZipCrypto, AES-128/192, split archives and archive append/in-place modification are unsupported.

CRC, size and AES authentication checks must pass before a read succeeds. Ordinary ZIP AES does not authenticate the catalog or hide names and timestamps. See <doc:PasswordsAndEncryption> for password handling and encrypted catalogs. Passwords are omitted from library-generated diagnostics. Secure erasure of strings and callback data is not guaranteed.
