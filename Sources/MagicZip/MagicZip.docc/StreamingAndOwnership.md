# Streaming and ownership

Process large files in chunks and keep archive sessions within their scope.

## Scoped sessions

``ZIPReader/withArchive(at:limits:body:)`` and ``ZIPWriter/withArchive(at:password:overwrite:body:)`` open an archive, run a synchronous throwing closure, and close the archive before returning. Writers publish the finished archive only after finalization succeeds.

Use the reader or writer only inside its closure. Sessions are not `Sendable`. Concurrent calls and reentry from a callback are rejected. Use separate sessions for parallel operations. Copied ``ZIPEntry`` values remain valid after the session closes.

## Async/await

`withArchiveAsync` runs a complete session on a background queue, with at most two sessions running at once across all reader and writer types.

```swift
func extractAssets(archive: URL, destination: URL) async throws -> [ZIPEntry] {
    try await ZIPReader.withArchiveAsync(at: archive) { reader in
        try reader.extract(to: destination, selection: .subtree("assets"))
        return reader.entries
    }
}
```

The body is `@Sendable` and returns a `Sendable` value. Capture immutable inputs, keep the session inside the body, and return metadata or data. The body and streaming callbacks are synchronous, so they cannot suspend or access main-actor state. Do not synchronously wait for another async archive operation from a callback. Async producers and `AsyncSequence` are not supported.

Caller cancellation reaches archive checkpoints, but task-local values and task identity do not propagate into the body. A queued operation cancelled before it starts skips its body when scheduled. A running operation checks cancellation between chunks and before publication. Native calls and user callbacks cannot be interrupted, and the await completes only after finalization and cleanup. Cancellation after the final publication checkpoint may still return success.

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

Each chunk is an owned `Data` value and can be retained. Keeping every chunk uses memory proportional to the file size.

Chunks are provisional until `read` returns successfully because size, CRC-32 or AES authentication checks can fail at the end. Discard chunks from a failed read. Use `extract` when a file should become visible only after verification. A failed read closes the current entry, allowing you to read another entry in the same session.

``ZIPReader/data(path:password:maximumBytes:)`` loads the complete entry and has a separate 16 MiB default cap. Prefer streaming for large files. Payload buffers stay bounded, while metadata memory grows with entry count and name bytes within the configured limits.

## Streaming writes

```swift
func repeatBytes(into archive: URL, count: Int) throws {
    try ZIPWriter.withArchive(at: archive) { writer in
        var remaining = count
        try writer.addStream(path: "payload.bin", compression: .store) { requested in
            guard remaining > 0 else {
                return nil
            }
            let size = min(remaining, requested)
            remaining -= size
            return Data(repeating: 42, count: size)
        }
    }
}
```

Return a nonempty `Data` no larger than `requested`, or `nil` at EOF. Requests are at most 64 KiB. Empty or oversized chunks throw. Streamed entries use ZIP64 even when small, so you do not need to predict the final size. Keep sources stable until reading finishes.

## Errors and cancellation

Streaming loops check task cancellation between chunks. Callbacks may also throw. Any failed addition invalidates the writer, even if the body catches the error. Start a new writer session to retry.

``ZIPError`` describes invalid paths, limits, unsupported features and backend failures. Callback and cancellation errors retain their original types. If an operation and its cleanup both fail, ``ZIPError/combined(primary:cleanup:)`` preserves both errors.

A backend error includes a typed operation, an optional entry path and the original numeric status. Use `backendStatus?.code` for recognized codes and `localizedDescription` for diagnostics:

```swift
do {
    try ZIPReader.withArchive(at: archiveURL) { reader in
        try reader.extract(to: outputURL, password: password)
    }
} catch let error as ZIPError {
    print(error.localizedDescription)
    if case let .backend(operation, path, status) = error {
        print(operation, path ?? "archive", status)
    }
}
```

Unknown backend codes retain their numeric status. `integrityError` covers both CRC and AES authentication failures. For combined errors, inspect both branches. `backendStatus` does not pick one. Diagnostic messages are English. Map typed errors to your own localized UI.
