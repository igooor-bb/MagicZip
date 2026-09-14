import Foundation

/// Creates ZIP archives with a separate password choice for each file.
///
/// ZIP allows files with different passwords and unencrypted files in the same archive.
/// Use ``ZIPWriter/withMixedArchive(at:overwrite:body:)`` to start a session,
/// or ``ZIPWriter/withMixedArchiveAsync(at:overwrite:body:)`` to wait asynchronously.
/// Names and metadata remain visible. See <doc:PasswordsAndEncryption> for examples.
///
/// The archive closure borrows the writer, so it cannot be stored or returned.
/// Calls must not overlap or call back into this writer. Any failed addition invalidates the session, even if the closure catches the
/// error.
///
/// See <doc:StreamingAndOwnership> for session behavior and <doc:SafetyAndLimits> for path,
/// resource and overwrite rules.
public struct MixedZIPWriter: ~Copyable {
    private let core: ArchiveWriter
    init(core: ArchiveWriter) {
        self.core = core
    }

    /// Adds in-memory data as a file in the archive.
    ///
    /// - Parameters:
    ///   - data: The file contents.
    ///   - path: The file's relative path inside the archive.
    ///   - compression: The compression method for this file.
    ///   - password: The password for this file, or `nil` to leave it unencrypted.
    ///   - modificationDate: The modification date to record in the archive.
    public func add(
        data: Data,
        path: String,
        compression: ZIPCompression = .deflate(),
        password: String?,
        modificationDate: Date = Date(),
    ) throws {
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
    ///   - password: The password for this file, or `nil` to leave it unencrypted.
    public func add(file url: URL, path: String, compression: ZIPCompression = .deflate(), password: String?) throws {
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
    ///   - password: The password for every file in this folder, or `nil` to leave them unencrypted.
    public func add(directory url: URL, path: String, compression: ZIPCompression = .deflate(), password: String?) throws {
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
    ///   - password: The password for this file, or `nil` to leave it unencrypted.
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
        password: String?,
        modificationDate: Date = Date(),
        producer: (Int) throws -> Data?,
    ) throws {
        try core.addStream(path: path, compression: compression, password: password, modificationDate: modificationDate, producer: producer)
    }
}
