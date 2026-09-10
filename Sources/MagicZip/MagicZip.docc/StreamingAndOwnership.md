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
