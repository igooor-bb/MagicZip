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

## Component budgets and traversal cost

Reader defaults are 256 path components and 100,000 distinct path nodes, configurable with
``ZIPLimits/maximumPathDepth`` and ``ZIPLimits/maximumPathNodes``. The final file or directory
name counts as one component; a trailing slash does not. Implicit parents consume nodes.
Writer budgets use the same finite defaults, plus 100,000 entries and 16 MiB of entry names.
Limit failures throw ``ZIPError/limitExceeded(_:)`` before an entry is opened or published.

The path registry uses a flat array and a hash index keyed by parent ID and folded component.
Expected insertion cost is linear in the input name bytes; registry storage is linear in
retained component bytes and nodes. It stores no full-path prefixes and has no recursive
object graph to destroy. Original UTF-8 spellings still detect aliases of implicit parents.

Source traversal uses iterative preorder DFS, sorting each directory once. Pending names
across all frames are capped at 100,000 names and 16 MiB of UTF-8 bytes. Cleanup uses iterative
postorder DFS with at most 256 pending names per level (at most 65,280 name bytes per level).
After deleting a batch, cleanup opens a fresh stream and enumerates the remaining children;
it never transfers `telldir` cookies between streams. Cleanup has no archive depth limit,
because a replaced destination may be deeper than the new archive's allowed paths.

Frames own component names, never descriptors or full-path copies. Traversal reopens each
component from the pinned root using `openat` and `O_NOFOLLOW`, checking closure of intermediate
FDs. Descriptor count is independent of depth. The tradeoff is O(sum of visited depths)
component opens, plus source sorting O(sum of k log k) for directories of width k. Cleanup
uses O(depth × batch size) name memory; source frame memory has the global budgets above.
These are bounds on library traversal state, not guarantees about filesystem kernel caches.
Source traversal checks cancellation during enumeration and between children; cleanup ignores
cancellation and attempts to finish, preserving an independent cleanup failure if it occurs.

## Sources overlapping creation output

Creation rejects a source object whose device/inode matches its private staging directory,
open ZIP output, or previous destination. This applies to direct file sources and traversed
trees, including hard links. A destination inside the source or a descendant therefore fails
before reading the transaction itself and cannot publish a partially created archive. Files
visited before the overlap is discovered may already have been read into private staging.
An existing destination is preserved. Names such as `.magiczip-user` are ordinary source names;
there is no wildcard exclusion based on the staging-name prefix.

Subtree selection preserves exact entry spelling. An explicit directory may be named `assets`
or `assets/`; either selection argument includes the directory and descendants with a component
boundary. An ordinary file named `assets` is not a subtree. Lookup remains case-sensitive.
