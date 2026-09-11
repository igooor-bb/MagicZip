import Foundation

/// A scoped ZIP writer with explicit per-entry passwords.
/// Metadata remains visible without a password. Directory entries are unencrypted.
/// The session is not Sendable; concurrent/reentrant calls fail. Any failed add invalidates it.
/// Escaped sessions reject writes after the scope ends.
public final class MixedZIPWriter {
    private let core: ArchiveWriter
    private init(core: ArchiveWriter) {
        self.core = core
    }

    /// Creates, closes and atomically publishes an archive. Failure preserves the old destination.
    /// Passwords must contain 1...128 UTF-8 bytes without NUL; nil means plaintext.
    public static func withArchive<T>(at url: URL, overwrite: ZIPOverwrite = .fail, body: (MixedZIPWriter) throws -> T) throws -> T {
        try withArchive(at: url, overwrite: overwrite, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        overwrite: ZIPOverwrite,
        cancellation: ArchiveCancellation?,
        body: (MixedZIPWriter) throws -> T,
    ) throws -> T {
        try ArchiveWriter.withArchive(at: url, overwrite: overwrite, cancellation: cancellation) { core in
            try body(MixedZIPWriter(core: core))
        }
    }

    /// Runs a synchronous scope on the bounded archive queue; cancellation waits for cleanup.
    public static func withArchiveAsync<T: Sendable>(
        at url: URL,
        overwrite: ZIPOverwrite = .fail,
        body: @escaping @Sendable (MixedZIPWriter) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, overwrite: overwrite, cancellation: cancellation, body: body)
        }
    }

    /// Adds bytes synchronously. Invalid paths, options or writes invalidate the session.
    public func add(
        data: Data,
        path: String,
        compression: ZIPCompression = .deflate(),
        password: String?,
        modificationDate: Date = Date(),
    ) throws {
        try core.add(data: data, path: path, compression: compression, password: password, modificationDate: modificationDate)
    }

    /// Streams a regular file; symlinks and sources overlapping the output transaction are rejected.
    public func add(file url: URL, path: String, compression: ZIPCompression = .deflate(), password: String?) throws {
        try core.add(file: url, path: path, compression: compression, password: password)
    }

    /// Adds a stable directory tree. Symlinks are rejected; depth and metadata are bounded.
    public func add(directory url: URL, path: String, compression: ZIPCompression = .deflate(), password: String?) throws {
        try core.add(directory: url, path: path, compression: compression, password: password)
    }

    /// Adds an unencrypted empty directory; appends a trailing slash if needed.
    public func addDirectory(path: String, modificationDate: Date = Date()) throws {
        try core.addDirectory(path: path, modificationDate: modificationDate)
    }

    /// Streams chunks of 1...65536 bytes, or nil at EOF. The producer must not reenter this writer.
    /// Producer errors invalidate the session. Paths are limited to 256 components; metadata to
    /// 100,000 entries, 100,000 path nodes and 16 MiB of names. No payload-sized allocation occurs.
    public func addStream(
        path: String,
        compression: ZIPCompression = .deflate(),
        password: String?,
        modificationDate: Date = Date(),
        producer: (Int) throws -> Data?,
    ) throws {
        try core.addStream(path: path, compression: compression, password: password, modificationDate: modificationDate, producer: producer)
    }
}
