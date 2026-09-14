import Foundation

/// Creates ZIP archives with an optional shared password.
///
/// Set a password when opening the archive to encrypt every file. Omit it to create an
/// unencrypted archive. ZIP file encryption leaves names and metadata visible.
/// Use ``withMixedArchive(at:overwrite:body:)`` to choose a password for each file.
/// See <doc:PasswordsAndEncryption> for password requirements and other encryption modes.
///
/// The archive closure borrows the writer, so it cannot be stored or returned.
/// Calls must not overlap or call back into this writer. Any failed addition invalidates the session, even if the closure catches the
/// error.
///
/// See <doc:StreamingAndOwnership> for session behavior and <doc:SafetyAndLimits> for path,
/// resource and overwrite rules.
public struct ZIPWriter: ~Copyable {
    private let core: ArchiveWriter
    private let password: String?

    /// Creates an archive using the supplied closure.
    ///
    /// The archive becomes visible at its destination after writing and finalization succeed.
    /// If an error occurs before publication, an existing destination is preserved. Cleanup errors
    /// can still be reported after the new archive is visible.
    ///
    /// - Parameters:
    ///   - url: The archive destination. Its parent must exist and its path must not contain symlinks.
    ///   - password: The password for all files, or `nil` to leave them unencrypted.
    ///   - overwrite: How to handle an existing destination.
    ///   - body: The work to perform with this writer. Use the writer only inside this closure.
    /// - Returns: The value returned by `body`.
    /// - Throws: ``ZIPError`` if creation fails. Errors thrown by `body` are preserved,
    ///   including any additional cleanup error.
    ///
    /// See <doc:PasswordsAndEncryption> for password requirements.
    public static func withArchive<T>(
        at url: URL,
        password: String? = nil,
        overwrite: ZIPOverwrite = .fail,
        body: (borrowing ZIPWriter) throws -> T,
    ) throws -> T {
        try withArchive(at: url, password: password, overwrite: overwrite, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        password: String? = nil,
        overwrite: ZIPOverwrite,
        cancellation: ArchiveCancellation?,
        body: (borrowing ZIPWriter) throws -> T,
    ) throws -> T {
        try withPassword(password) { _ in }
        return try ArchiveWriter.withArchive(at: url, overwrite: overwrite, cancellation: cancellation) { core in
            try body(ZIPWriter(core: core, password: password))
        }
    }

    /// Creates an archive on a background queue while the calling task waits asynchronously.
    ///
    /// The closure uses the same API as `withArchive` and runs synchronously. Return `Sendable`
    /// results such as metadata or data, and use the writer only inside the closure.
    /// Cancellation does not interrupt an active callback. The await completes after finalization
    /// and cleanup. See <doc:StreamingAndOwnership> for cancellation behavior.
    public static func withArchiveAsync<T: Sendable>(
        at url: URL,
        password: String? = nil,
        overwrite: ZIPOverwrite = .fail,
        body: @escaping @Sendable (borrowing ZIPWriter) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, password: password, overwrite: overwrite, cancellation: cancellation, body: body)
        }
    }

    /// Creates an archive with a separate password choice for each file.
    ///
    /// The archive becomes visible at its destination after writing and finalization succeed.
    /// If an error occurs before publication, an existing destination is preserved. Cleanup errors
    /// can still be reported after the new archive is visible.
    ///
    /// - Parameters:
    ///   - url: The archive destination. Its parent must exist and its path must not contain symlinks.
    ///   - overwrite: How to handle an existing destination.
    ///   - body: The work to perform with this writer. Use the writer only inside this closure.
    /// - Returns: The value returned by `body`.
    /// - Throws: ``ZIPError`` if creation fails. Errors thrown by `body` are preserved,
    ///   including any additional cleanup error.
    ///
    /// See <doc:PasswordsAndEncryption> for password requirements.
    public static func withMixedArchive<T>(
        at url: URL,
        overwrite: ZIPOverwrite = .fail,
        body: (borrowing MixedZIPWriter) throws -> T,
    ) throws -> T {
        try withMixedArchive(at: url, overwrite: overwrite, cancellation: nil, body: body)
    }

    static func withMixedArchive<T>(
        at url: URL,
        overwrite: ZIPOverwrite,
        cancellation: ArchiveCancellation?,
        body: (borrowing MixedZIPWriter) throws -> T,
    ) throws -> T {
        try ArchiveWriter.withArchive(at: url, overwrite: overwrite, cancellation: cancellation) { core in
            try body(MixedZIPWriter(core: core))
        }
    }

    /// Creates an archive with per-file passwords on a background queue.
    ///
    /// The closure uses the same API as `withMixedArchive` and runs synchronously. Return `Sendable`
    /// results such as metadata or data, and use the writer only inside the closure.
    /// Cancellation does not interrupt an active callback. The await completes after finalization
    /// and cleanup. See <doc:StreamingAndOwnership> for cancellation behavior.
    public static func withMixedArchiveAsync<T: Sendable>(
        at url: URL,
        overwrite: ZIPOverwrite = .fail,
        body: @escaping @Sendable (borrowing MixedZIPWriter) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withMixedArchive(at: url, overwrite: overwrite, cancellation: cancellation, body: body)
        }
    }

    /// Adds in-memory data as a file in the archive.
    ///
    /// - Parameters:
    ///   - data: The file contents.
    ///   - path: The file's relative path inside the archive.
    ///   - compression: The compression method for this file.
    ///   - modificationDate: The modification date to record in the archive.
    public func add(data: Data, path: String, compression: ZIPCompression = .deflate(), modificationDate: Date = Date()) throws {
        try core.add(data: data, path: path, compression: compression, password: password, modificationDate: modificationDate)
    }

    /// Adds a file from disk to the archive.
    ///
    /// The file is read in chunks. Keep it unchanged until this call finishes.
    ///
    /// - Parameters:
    ///   - url: The source file. Symlinks and sources overlapping the archive output are rejected.
    ///   - path: The file's relative path inside the archive.
    ///   - compression: The compression method for this file.
    public func add(file url: URL, path: String, compression: ZIPCompression = .deflate()) throws {
        try core.add(file: url, path: path, compression: compression, password: password)
    }

    /// Adds a folder and its contents to the archive.
    ///
    /// Keep the source tree unchanged until this call finishes. Symlinks, special files and sources
    /// that overlap the archive output are rejected.
    ///
    /// - Parameters:
    ///   - url: The source folder.
    ///   - path: The folder's relative path inside the archive, included before each child's name.
    ///   - compression: The compression method for all files in the folder.
    public func add(directory url: URL, path: String, compression: ZIPCompression = .deflate()) throws {
        try core.add(directory: url, path: path, compression: compression, password: password)
    }

    /// Adds an empty directory to the archive.
    ///
    /// - Parameters:
    ///   - path: The directory's relative path. A trailing slash is added if needed.
    ///   - modificationDate: The modification date to record in the archive.
    ///
    /// Directory entries are not encrypted.
    public func addDirectory(path: String, modificationDate: Date = Date()) throws {
        try core.addDirectory(path: path, modificationDate: modificationDate)
    }

    /// Adds a file from a sequence of data chunks.
    ///
    /// Use this method when data comes from a producer rather than a file or a complete `Data` value.
    ///
    /// - Parameters:
    ///   - path: The file's relative path inside the archive.
    ///   - compression: The compression method for this file.
    ///   - modificationDate: The modification date to record in the archive.
    ///   - producer: Called synchronously with the maximum requested chunk size, up to 64 KiB.
    ///     Return nonempty data no larger than requested, or `nil` when finished. Do not call
    ///     this writer again from the producer.
    /// - Throws: An error if a chunk is invalid or writing fails. Producer errors are preserved.
    ///   Any failure invalidates the writer.
    ///
    /// Streamed entries use ZIP64 even when small. See <doc:StreamingAndOwnership> for an example
    /// and <doc:SafetyAndLimits> for archive limits.
    public func addStream(
        path: String,
        compression: ZIPCompression = .deflate(),
        modificationDate: Date = Date(),
        producer: (Int) throws -> Data?,
    ) throws {
        try core.addStream(path: path, compression: compression, password: password, modificationDate: modificationDate, producer: producer)
    }
}
