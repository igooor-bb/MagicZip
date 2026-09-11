import Foundation

/// Creates minizip-ng CDCD archives with an encrypted catalog and AES-256 regular files.
/// Requires a compatible reader; this is not PKWARE central-directory encryption.
/// Names and timestamps are masked in local headers. Entry count, payload boundaries,
/// compression methods and approximate sizes remain observable. Catalog memory is capped at 64 MiB.
/// The session is not Sendable; concurrent/reentrant calls fail. Any failed add invalidates it.
/// Escaped sessions reject writes after the scope ends.
public final class SecureZIPWriter {
    private let core: ArchiveWriter
    private let password: String
    private init(core: ArchiveWriter, password: String) {
        self.core = core
        self.password = password
    }

    /// Creates, closes and atomically publishes an archive. Failure preserves the old destination.
    /// The required password must contain 1...128 UTF-8 bytes without NUL.
    public static func withArchive<T>(
        at url: URL,
        password: String,
        overwrite: ZIPOverwrite = .fail,
        body: (SecureZIPWriter) throws -> T,
    ) throws -> T {
        try withArchive(at: url, password: password, overwrite: overwrite, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        password: String,
        overwrite: ZIPOverwrite,
        cancellation: ArchiveCancellation?,
        body: (SecureZIPWriter) throws -> T,
    ) throws -> T {
        try withPassword(password) { _ in }
        return try ArchiveWriter.withArchive(at: url, overwrite: overwrite, cancellation: cancellation, securePassword: password) { core in
            try body(SecureZIPWriter(core: core, password: password))
        }
    }

    /// Runs a synchronous scope on the bounded archive queue; cancellation waits for cleanup.
    public static func withArchiveAsync<T: Sendable>(
        at url: URL,
        password: String,
        overwrite: ZIPOverwrite = .fail,
        body: @escaping @Sendable (SecureZIPWriter) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, password: password, overwrite: overwrite, cancellation: cancellation, body: body)
        }
    }

    /// Adds bytes synchronously. Invalid paths, options or writes invalidate the session.
    public func add(data: Data, path: String, compression: ZIPCompression = .deflate(), modificationDate: Date = Date()) throws {
        try core.add(data: data, path: path, compression: compression, password: password, modificationDate: modificationDate)
    }

    /// Streams a regular file; symlinks and sources overlapping the output transaction are rejected.
    public func add(file url: URL, path: String, compression: ZIPCompression = .deflate()) throws {
        try core.add(file: url, path: path, compression: compression, password: password)
    }

    /// Adds a stable directory tree. Symlinks are rejected; depth and metadata are bounded.
    public func add(directory url: URL, path: String, compression: ZIPCompression = .deflate()) throws {
        try core.add(directory: url, path: path, compression: compression, password: password)
    }

    /// Adds an empty directory whose name is protected by the catalog; appends a slash if needed.
    public func addDirectory(path: String, modificationDate: Date = Date()) throws {
        try core.addDirectory(path: path, modificationDate: modificationDate)
    }

    /// Streams chunks of 1...65536 bytes, or nil at EOF. The producer must not reenter this writer.
    /// Producer errors invalidate the session. Paths are limited to 256 components; metadata to
    /// 100,000 entries, 100,000 path nodes and 16 MiB of names. No payload-sized allocation occurs.
    public func addStream(
        path: String,
        compression: ZIPCompression = .deflate(),
        modificationDate: Date = Date(),
        producer: (Int) throws -> Data?,
    ) throws {
        try core.addStream(path: path, compression: compression, password: password, modificationDate: modificationDate, producer: producer)
    }
}
