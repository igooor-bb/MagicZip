# Streaming and ownership

Keep archive payload memory bounded and handle finalization explicitly.

## Scoped sessions

``ZIPReader/withArchive(at:limits:body:)`` and ``ZIPWriter/withArchive(at:overwrite:body:)``
create one native handle, invoke a synchronous throwing closure, and check closure of the
archive before returning. The writer then publishes its temporary file atomically.
A `deinit` is only an exception fallback, never the successful finalization path.

Internally, a `~Copyable` owner prevents accidental copies of the C handle. Public sessions
are reference types so throwing callback APIs remain familiar. They do not conform to
`Sendable`. A lock rejects overlapping/reentrant operations without blocking a callback
on itself. Sessions retained past their scope reject further native operations; copied
``ZIPEntry`` values and the reader's immutable metadata remain valid.

File opens and output creation return an internal noncopyable `FileDescriptor` owner.
The native archive initializer takes a `consuming FileDescriptor`: ownership leaves the
caller, and the adapter becomes responsible for closing on both success and failure.
Its transfer method uses `discard self` to suppress the Swift owner's `deinit` without
closing the transferred resource. Temporary filesystem operations accept
`borrowing FileDescriptor`, keeping the owner alive for the duration of each operation.

Files used directly by Swift have consuming scopes that borrow the descriptor to their
body and explicitly check close afterward, preserving simultaneous body/close errors.
Checked close relinquishes ownership before the POSIX call, so an error does not trigger
a second close in `deinit`. `NativeArchive.close()` remains `mutating`: it leaves the
stored archive owner in its closed state, which supports escaped-session rejection.

## Asynchronous callers

``ZIPReader/withArchiveAsync(at:limits:body:)`` and
``ZIPWriter/withArchiveAsync(at:overwrite:body:)`` suspend the calling task and run a complete
synchronous session on a background queue. Up to two async sessions execute at once across
readers and writers. Each handle is created, used and closed by its own worker job.

```swift
func extractAssets(archive: URL, destination: URL) async throws -> [ZIPEntry] {
    try await ZIPReader.withArchiveAsync(at: archive) { reader in
        try reader.extract(to: destination, selection: .subtree("assets"))
        return reader.entries
    }
}
```

The body is `@Sendable` and the result must be `Sendable`. Keep sessions inside the body;
return copied metadata or data instead. The body and stream callbacks are synchronous:
they cannot suspend or access main-actor state. Do not synchronously wait for another async
archive job from a worker callback. Async producers and `AsyncSequence` are not provided.

Caller cancellation is explicitly forwarded to the worker; task-local values and task identity
are not. A cancelled queued job skips its body upon admission. Running jobs check cancellation
between chunks and before publication. Await returns only after finalization and cleanup, and
cannot interrupt native calls or user callbacks. Body code that performs no archive operations
must finish or throw on its own. Cancellation after the final publication checkpoint may still
return success with the published output; no post-publication cancellation check removes it.

## Streaming reads

```swift
func countBytes(in archive: URL) throws -> Int64 {
    try ZIPReader.withArchive(at: archive) { reader in
        var count: Int64 = 0
        try reader.read(path: "video.mov") { chunk in
            count += Int64(chunk.count)
        }
        return count
    }
}
```

The callback receives owned `Data`, so retaining a chunk is safe. Retaining every chunk
naturally defeats bounded memory. Chunks are provisional until the method returns:
length, CRC-32 and AES HMAC validation can fail at the end. Use transactional extraction
when unverified bytes must never become visible as a completed file.

``ZIPReader/data(path:password:maximumBytes:)`` intentionally allocates a complete entry,
with an additional default 16 MiB budget. Prefer streaming for large payloads.

## Streaming writes

```swift
func repeatBytes(into archive: URL, count: Int) throws {
    try ZIPWriter.withArchive(at: archive) { writer in
        var remaining = count
        try writer.addStream(path: "payload.bin", compression: .store) { requested in
            guard remaining > 0 else { return nil }
            let size = min(remaining, requested)
            remaining -= size
            return Data(repeating: 42, count: size)
        }
    }
}
```

Return 1...64 KiB or `nil` at EOF. Empty/nonconforming chunks fail explicitly. ZIP64 is
forced for streamed entries, so crossing 4 GiB does not require predicting source size.
Sources must remain stable while being read. Archive modification/append is not supported.

Payload buffers are bounded; metadata uses O(entry count + name bytes) memory. Readers
and writers cap metadata, and readers also cap advertised/actual output and expansion
ratio. This is not constant-memory storage for an unlimited number of tiny entries.

## Cancellation and failure

All stream loops check current Swift task cancellation; callback throws can also cancel
synchronous operations. A failed writer operation poisons the session, even if caught by
the body. Closing an entry and closing the archive are checked independently. When a body
fails and cleanup fails too, ``ZIPError/combined(primary:cleanup:)`` preserves both errors.

A failed read closes the current entry, allowing another independent entry to be read.
The caller must discard any provisional chunks received from the failed operation.

## Internal borrowed buffers and directory ownership

File creation and extraction share the same entry loops as public streaming callbacks.
File input uses a noncopyable `StreamBuffer` owning one uninitialized 64 KiB allocation.
Reading reuses one Swift-managed byte array per entry (64 KiB by default); the array already
owns its storage and needs no manual resource owner. Synchronous borrowing scopes pass only
initialized bytes to C or the filesystem. File input does not
allocate and zero an array or construct owned `Data` per chunk. Extraction does not copy
C output into `Data`. Public reading still copies each delivered chunk into independent owned
`Data`, including when a client keeps earlier chunks. Buffer size and cancellation/integrity
checkpoints are unchanged.

A noncopyable directory-stream owner consumes a descriptor only when `fdopendir` succeeds;
failed construction checks descriptor closure. Its consuming checked scope lends the stream
and closes it exactly once, combining enumeration and close errors. Traversal frames never
own this stream. The transaction retains its two noncopyable directory descriptors to anchor
its lifetime; the C adapter owns the `FILE*` and backend handles after consuming the input FD.
Entry open/close operations remain scoped state transitions of the exclusive native archive
owner, rather than independently owning the same handle twice.

Reader initialization explicitly closes the native archive if metadata scanning fails,
including cancellation. A simultaneous close failure becomes a combined error with the scan
failure first. Instance-local internal hooks exercise this path without public injection API
or process-wide descriptor substitution.

The adapter compares the upstream running CRC against the central-directory CRC for plaintext
and AE-1, through a private patched accessor. This avoids a second CRC update without relying
on upstream `read_close`'s compressed-size condition, which is insufficient for AES overhead.
AE-2 continues to use HMAC; compressed/uncompressed sizes and AES authentication are checked
independently. Store's raw codec is rebound to the still-open file after AES authentication,
so checked closure does not fail merely because authentication closed its AES base stream.
