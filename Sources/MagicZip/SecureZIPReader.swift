import Foundation

/// Reads archives whose file contents and catalog are encrypted.
///
/// The password unlocks and verifies the catalog before your archive closure runs.
/// File contents are verified when read. The closure borrows the reader, so it cannot be
/// stored or returned. Use separate sessions for parallel reads. Calls must not overlap
/// or call back into this reader.
///
/// - Important: This reader accepts minizip-ng CDCD archives, including those created by
///   ``SecureZIPWriter``. Use ``ZIPReader`` for ordinary ZIP archives.
///
/// See <doc:PasswordsAndEncryption> for compatibility and catalog limits.
public struct SecureZIPReader: ~Copyable {
    private let core: ArchiveReader
    private let password: String

    /// The entries from the verified archive catalog.
    ///
    /// Listing entries does not read or verify file contents. Entry metadata remains usable
    /// after the session closes.
    public var entries: [ZIPEntry] {
        core.entries
    }

    /// Opens an encrypted-catalog archive for reading within a closure.
    ///
    /// The catalog is verified before `body` runs, and the archive is closed before this method returns.
    ///
    /// - Parameters:
    ///   - url: The archive file. Its path must not contain symlinks.
    ///   - password: The password for the catalog and file contents.
    ///   - limits: Limits on entry metadata and decompressed files. A separate catalog limit also applies.
    ///   - body: The work to perform with this reader. Use it only inside this closure.
    /// - Returns: The value returned by `body`.
    /// - Throws: An error if the catalog cannot be opened or verified. Body and cleanup errors are preserved.
    public static func withArchive<T>(
        at url: URL,
        password: String,
        limits: ZIPLimits = ZIPLimits(),
        body: (borrowing SecureZIPReader) throws -> T,
    ) throws -> T {
        try withArchive(at: url, password: password, limits: limits, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        password: String,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        body: (borrowing SecureZIPReader) throws -> T,
    ) throws -> T {
        try withPassword(password) { _ in }
        return try ArchiveReader.withArchive(at: url, limits: limits, cancellation: cancellation, securePassword: password) { core in
            try body(SecureZIPReader(core: core, password: password))
        }
    }

    /// Reads an encrypted-catalog archive on a background queue.
    ///
    /// The closure follows the same rules as `withArchive` and runs synchronously. Use the reader
    /// only inside it and return `Sendable` results such as data or metadata.
    /// The await completes after the archive closes and cleanup finishes, including on cancellation.
    /// See <doc:StreamingAndOwnership> for the full async contract.
    public static func withArchiveAsync<T: Sendable>(
        at url: URL,
        password: String,
        limits: ZIPLimits = ZIPLimits(),
        body: @escaping @Sendable (borrowing SecureZIPReader) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, password: password, limits: limits, cancellation: cancellation, body: body)
        }
    }

    /// Finds an entry by its archive path.
    ///
    /// - Parameter path: The exact path as listed in ``entries``, including any trailing slash.
    /// - Returns: The entry's metadata, or `nil` if no entry matches.
    ///
    /// Lookup is case-sensitive and does not read file contents.
    public func entry(at path: String) -> ZIPEntry? {
        core.entry(at: path)
    }

    /// Reads a file's contents in chunks using the archive password.
    ///
    /// - Parameters:
    ///   - path: The exact entry path.
    ///   - chunkSize: The maximum bytes per chunk, from 1 byte to 1 MiB. Defaults to 64 KiB.
    ///   - consumer: Called synchronously with each `Data` chunk. You can retain chunks or throw
    ///     to stop reading. Do not call this reader again from the callback.
    /// - Throws: A reading, verification, callback or cancellation error.
    ///
    /// - Important: Chunks are not fully verified until this method returns successfully.
    ///   Discard data from a failed read.
    public func read(path: String, chunkSize: Int = 64 * 1024, consumer: (Data) throws -> Void) throws {
        try core.read(path: path, password: password, chunkSize: chunkSize, consumer: consumer)
    }

    /// Reads an entry's complete contents into memory using the archive password.
    ///
    /// - Parameters:
    ///   - path: The exact entry path.
    ///   - maximumBytes: The maximum returned data size. Defaults to 16 MiB and must be nonnegative.
    /// - Returns: Verified file data, or empty data for an empty file or directory.
    /// - Throws: A reading or verification error, or ``ZIPError`` if a size limit is exceeded.
    ///
    /// The reader's ``ZIPLimits`` also apply. Prefer streaming for large files.
    public func data(path: String, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        try core.data(path: path, password: password, maximumBytes: maximumBytes)
    }

    /// Extracts files to a destination folder using the archive password.
    ///
    /// - Parameters:
    ///   - destination: The output folder. Missing parent directories are created. Parent directory aliases are supported.
    ///   - selection: The entries to extract. Defaults to all entries.
    ///   - overwrite: How to handle an existing destination. Defaults to failing if it exists.
    /// - Throws: An extraction, verification or cancellation error.
    ///
    /// Failure before publication preserves an existing destination. Cleanup can fail after the new
    /// result becomes visible. Folders are replaced as a whole, and original permissions and timestamps
    /// are not restored. See <doc:SafetyAndLimits> for extraction rules.
    public func extract(to destination: URL, selection: ZIPSelection = .all, overwrite: ZIPOverwrite = .fail) throws {
        try core.extract(to: destination, selection: selection, password: password, overwrite: overwrite)
    }
}
