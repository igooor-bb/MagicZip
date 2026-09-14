import Foundation

/// Reads ZIP entries and extracts files from an archive.
///
/// Open a reader with ``withArchive(at:limits:body:)``. The closure borrows the reader,
/// so it cannot be stored or returned. Return data or entry metadata to use after the session.
/// Use separate sessions for parallel reads. Calls on one reader must not overlap or call
/// back into it from a callback.
///
/// See <doc:StreamingAndOwnership> for streaming and async usage, and <doc:SafetyAndLimits>
/// for supported formats and extraction rules.
public struct ZIPReader: ~Copyable {

    /// The archive's entries in their recorded order.
    ///
    /// Listing entries does not read their file contents. This metadata remains available after
    /// the session closes.
    public var entries: [ZIPEntry] {
        core.entries
    }

    private let core: ArchiveReader

    /// Opens an archive for reading within a closure.
    ///
    /// The archive is closed before this method returns.
    ///
    /// - Parameters:
    ///   - url: The archive file. Its path must not contain symlinks.
    ///   - limits: Limits on archive metadata and decompressed data.
    ///   - body: The work to perform with this reader. Use it only inside this closure.
    /// - Returns: The value returned by `body`.
    /// - Throws: ``ZIPError`` if the archive cannot be opened or validated. Errors thrown by
    ///   `body` are preserved, including any additional error while closing the archive.
    ///
    /// ```swift
    /// let names = try ZIPReader.withArchive(at: archiveURL) { reader in
    ///     reader.entries.map(\.path)
    /// }
    /// ```
    public static func withArchive<T>(at url: URL, limits: ZIPLimits = ZIPLimits(), body: (borrowing ZIPReader) throws -> T) throws -> T {
        try withArchive(at: url, limits: limits, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        securePassword: String? = nil,
        body: (borrowing ZIPReader) throws -> T,
    ) throws -> T {
        try ArchiveReader.withArchive(at: url, limits: limits, cancellation: cancellation, securePassword: securePassword) { core in
            try body(ZIPReader(core: core))
        }
    }

    /// Finds an entry by its archive path.
    ///
    /// - Parameter path: The exact path as listed in ``entries``, including any trailing slash.
    /// - Returns: The entry's metadata, or `nil` if no entry matches.
    ///
    /// Lookup is case-sensitive and does not read file contents. The result remains usable
    /// after the session closes.
    public func entry(at path: String) -> ZIPEntry? {
        core.entry(at: path)
    }

    /// Reads a file's contents in chunks.
    ///
    /// - Parameters:
    ///   - path: The exact entry path.
    ///   - password: The file's password, or `nil` for an unencrypted file.
    ///   - chunkSize: The maximum bytes per chunk, from 1 byte to 1 MiB. Defaults to 64 KiB.
    ///   - consumer: Called synchronously with each `Data` chunk. You can retain chunks or throw
    ///     to stop reading. Do not call this reader again from the callback.
    /// - Throws: ``ZIPError`` if reading or verification fails. Callback and cancellation errors
    ///   are preserved.
    ///
    /// - Important: Chunks are not fully verified until this method returns successfully.
    ///   Discard data from a failed read, or use extraction to publish only verified files.
    ///
    /// See <doc:StreamingAndOwnership> for examples and <doc:PasswordsAndEncryption> for passwords.
    public func read(
        path: String,
        password: String? = nil,
        chunkSize: Int = 64 * 1024,
        consumer: (Data) throws -> Void,
    ) throws {
        try core.read(path: path, password: password, chunkSize: chunkSize, consumer: consumer)
    }

    /// Reads an entry's complete contents into memory.
    ///
    /// Prefer ``read(path:password:chunkSize:consumer:)`` for large files.
    ///
    /// - Parameters:
    ///   - path: The exact entry path.
    ///   - password: The file's password, or `nil` for an unencrypted file.
    ///   - maximumBytes: The maximum returned data size. Defaults to 16 MiB and must be nonnegative.
    /// - Returns: Verified file data, or empty data for an empty file or directory.
    /// - Throws: A reading or verification error, or ``ZIPError`` if the size limit is exceeded.
    ///
    /// The reader's ``ZIPLimits`` also apply.
    public func data(path: String, password: String? = nil, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        try core.data(path: path, password: password, maximumBytes: maximumBytes)
    }

    /// Extracts files to a destination folder.
    ///
    /// The completed result replaces the destination as a whole, without merging folders.
    /// Failure before publication preserves an existing destination. If cleanup fails after
    /// publication, the method throws but the new result is already visible.
    ///
    /// - Parameters:
    ///   - destination: The output folder. Its parent must exist and its path must not contain symlinks.
    ///   - selection: The entries to extract. Defaults to all entries.
    ///   - password: A shared password for the selected encrypted files.
    ///   - overwrite: How to handle an existing destination. Defaults to failing if it exists.
    /// - Throws: ``ZIPError`` if extraction fails, or a cancellation error if cancellation is observed.
    ///
    /// Only selected file contents are read. Original permissions and timestamps are not restored.
    /// See <doc:SafetyAndLimits> for extraction rules.
    ///
    /// ```swift
    /// try ZIPReader.withArchive(at: archiveURL) { reader in
    ///     try reader.extract(to: outputURL, selection: .subtree("assets"))
    /// }
    /// ```
    public func extract(
        to destination: URL,
        selection: ZIPSelection = .all,
        password: String? = nil,
        overwrite: ZIPOverwrite = .fail,
    ) throws {
        try core.extract(to: destination, selection: selection, password: password, overwrite: overwrite)
    }

    /// Extracts files using a separate password for each encrypted entry.
    ///
    /// Uses the same destination and overwrite rules as ``extract(to:selection:password:overwrite:)``.
    /// See <doc:PasswordsAndEncryption> for an example.
    ///
    /// - Parameters:
    ///   - destination: The output folder. Its parent must exist and its path must not contain symlinks.
    ///   - selection: The entries to extract. Defaults to all entries.
    ///   - overwrite: How to handle an existing destination.
    ///   - passwordProvider: Called once per selected encrypted entry, and never for unencrypted
    ///     or unselected entries. Return that entry's password. Do not call this reader from the provider.
    /// - Throws: An extraction error if a password is missing or incorrect. Provider errors are preserved.
    ///
    /// Handle retries and password caching in your application. Treat metadata passed to the provider
    /// as untrusted input. Failure before publication preserves an existing destination.
    public func extract(
        to destination: URL,
        selection: ZIPSelection = .all,
        overwrite: ZIPOverwrite = .fail,
        passwordProvider: (ZIPEntry) throws -> String?,
    ) throws {
        try core.extract(to: destination, selection: selection, overwrite: overwrite, passwordProvider: passwordProvider)
    }
}
