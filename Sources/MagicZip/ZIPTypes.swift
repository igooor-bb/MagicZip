import Foundation

/// An error encountered while reading or creating an archive.
///
/// Cases describe the failure and include path or operation details where available.
/// Library-generated diagnostics never include passwords. Callback errors, including
/// `CancellationError`, retain their original types.
///
/// If both an operation and its cleanup fail, ``combined(primary:cleanup:)`` preserves both errors.
/// See <doc:StreamingAndOwnership> for error handling.
public indirect enum ZIPError: Error {

    /// The ZIP engine could not complete an operation.
    ///
    /// - Parameters:
    ///   - operation: The operation that failed.
    ///   - path: The entry path, when applicable.
    ///   - status: The original backend status. Use ``ZIPError/backendStatus`` for readable diagnostics.
    ///
    /// Raw backend codes are diagnostic details and may vary with the backend version.
    case backend(operation: ZIPBackendOperation, path: String?, status: Int32)

    /// A file or directory operation failed.
    ///
    /// - Parameters:
    ///   - operation: The operation that failed.
    ///   - path: The affected filesystem path.
    ///   - code: The underlying POSIX error code.
    case fileSystem(operation: ZIPFileSystemOperation, path: String, code: Int32)

    /// The archive session has closed or was invalidated by an earlier failure.
    case closed

    /// The session is already performing another operation.
    ///
    /// Wait for the current operation to finish. Do not call the same session from one of its callbacks.
    case busy

    /// An argument does not meet the operation's requirements.
    case invalidArgument(String)

    /// An entry path is not safe to use.
    ///
    /// See <doc:SafetyAndLimits> for accepted paths.
    case unsafePath(String)

    /// Entry paths conflict with one another.
    case conflictingPath(String)

    /// The archive requires a feature that MagicZip does not support.
    case unsupported(path: String?, feature: String)

    /// The operation exceeds an archive resource limit.
    case limitExceeded(String)

    /// The archive has no entry at the requested path.
    case entryNotFound(String)

    /// An operation and its cleanup both failed.
    ///
    /// Inspect `primary` for the original failure and `cleanup` for the error encountered while
    /// closing resources or removing temporary output.
    case combined(primary: any Error, cleanup: any Error)
}

/// The compression method to use when adding a file.
public enum ZIPCompression: Sendable, Equatable {

    /// Stores the file without compression.
    case store

    /// Compresses the file using Deflate.
    ///
    /// - Parameter level: The balance between compression speed and output size. Defaults to `.balanced`.
    case deflate(level: DeflateLevel = .balanced)

    /// The compression effort used by Deflate.
    ///
    /// Higher levels favor smaller output over speed. Use ``fastest``, ``balanced`` or
    /// ``bestCompression`` for common choices, or select a specific level.
    public enum DeflateLevel: Int, Sendable, CaseIterable {

        /// Uses compression level 1, favoring speed.
        case level1 = 1

        /// Uses compression level 2.
        case level2 = 2

        /// Uses compression level 3.
        case level3 = 3

        /// Uses compression level 4.
        case level4 = 4

        /// Uses compression level 5.
        case level5 = 5

        /// Uses compression level 6, balancing speed and output size.
        case level6 = 6

        /// Uses compression level 7.
        case level7 = 7

        /// Uses compression level 8.
        case level8 = 8

        /// Uses compression level 9, favoring smaller output.
        case level9 = 9

        /// The fastest level that compresses file contents, equivalent to ``level1``.
        public static let fastest: Self = .level1

        /// The default balance of speed and output size, equivalent to ``level6``.
        public static let balanced: Self = .level6

        /// The highest compression effort, equivalent to ``level9``.
        public static let bestCompression: Self = .level9
    }
}

/// The encryption used for an archive entry.
///
/// Supply passwords to the reader or writer. See <doc:PasswordsAndEncryption> for usage.
public enum ZIPEncryption: Sendable, Equatable {

    /// An unencrypted entry.
    case none

    /// The entry uses AES-256 encryption.
    ///
    /// MagicZip reads WinZIP AE-1 and AE-2 entries and writes AE-2 entries.
    case aes256

    /// The entry uses an unsupported encryption method.
    ///
    /// Its metadata can be listed, but reading its contents fails.
    case unsupported
}

/// Information about a file or directory in an archive.
///
/// Metadata can be retained and shared after the reader closes. Listing an entry does not
/// verify its contents. Treat metadata from an untrusted archive as untrusted input.
public struct ZIPEntry: Sendable, Equatable {

    /// The entry's path inside the archive.
    ///
    /// Paths use the archive's original UTF-8 spelling. Directory names may omit a trailing slash.
    public let path: String

    /// Whether the entry is a directory.
    public let isDirectory: Bool

    /// The entry's compressed size in bytes.
    ///
    /// Includes encryption overhead for encrypted entries.
    public let compressedSize: Int64

    /// The entry's uncompressed size in bytes, as recorded in the archive.
    ///
    /// The actual size is checked when the entry is read.
    public let uncompressedSize: Int64

    /// The modification date recorded in the archive.
    ///
    /// Precision and timezone handling depend on the program that created it.
    public let modificationDate: Date

    /// The compression method recorded in the archive.
    ///
    /// This is the ZIP method identifier, including methods MagicZip cannot read.
    /// Store is 0 and Deflate is 8.
    public let compressionMethod: UInt16

    /// The entry's encryption method.
    public let encryption: ZIPEncryption

    /// The checksum recorded for the entry.
    ///
    /// This is the archive's CRC-32 value. AE-2 encrypted entries normally store zero and use
    /// AES authentication instead. Reading the entry performs the applicable integrity checks.
    public let crc32: UInt32

    let position: Int64
}

/// Limits on archive metadata and decompressed data.
///
/// Choose limits appropriate to the archives your application expects. The reader checks
/// recorded entry sizes when opening an archive and actual output while reading. The total
/// output limit applies separately to each read or extraction and counts only selected entries.
///
/// See <doc:SafetyAndLimits> for defaults and examples of how path limits are counted.
public struct ZIPLimits: Sendable {

    /// Maximum number of entries, including directories.
    public var maximumEntries: Int

    /// The maximum combined size of entry paths in UTF-8 bytes.
    public var maximumPathBytes: Int

    /// The maximum number of components in an entry path.
    ///
    /// Includes the final file or directory name. A trailing slash does not add a component.
    public var maximumPathDepth: Int

    /// The maximum number of distinct path nodes.
    ///
    /// Includes parent directories implied by entry paths, even when they have no explicit entries.
    /// Shared parents count once.
    public var maximumPathNodes: Int

    /// The maximum uncompressed size of a single entry, in bytes.
    ///
    /// Applies to both its recorded size and the data produced when reading it.
    public var maximumEntryBytes: Int64

    /// The maximum uncompressed bytes produced by one read or extraction.
    public var maximumTotalBytes: Int64

    /// The maximum allowed expansion ratio when decompressing an entry.
    ///
    /// Calculated as uncompressed size divided by compressed size, treating a zero compressed
    /// size as one byte. Highly repetitive data may exceed this limit even in a valid archive.
    public var maximumCompressionRatio: Double

    /// Creates a set of archive resource limits.
    ///
    /// Limits are validated when opening a reader. All size and count limits must be nonnegative.
    /// The expansion ratio must be finite and positive. These are application limits, not ZIP64
    /// format limits.
    ///
    /// - Parameters:
    ///   - maximumEntries: The entry count, including directories. Defaults to 100,000.
    ///   - maximumPathBytes: The combined UTF-8 size of entry paths. Defaults to 16 MiB.
    ///   - maximumEntryBytes: The uncompressed bytes per entry. Defaults to 1 GiB.
    ///   - maximumTotalBytes: The uncompressed bytes per selected operation. Defaults to 4 GiB.
    ///   - maximumCompressionRatio: The allowed expansion ratio. Defaults to 1,000.
    ///   - maximumPathDepth: The components per path, including the final name. Defaults to 256.
    ///   - maximumPathNodes: The distinct path nodes, including implied parents. Defaults to 100,000.
    public init(
        maximumEntries: Int = 100_000,
        maximumPathBytes: Int = 16 * 1024 * 1024,
        maximumEntryBytes: Int64 = 1024 * 1024 * 1024,
        maximumTotalBytes: Int64 = 4 * 1024 * 1024 * 1024,
        maximumCompressionRatio: Double = 1000,
        maximumPathDepth: Int = 256,
        maximumPathNodes: Int = 100_000,
    ) {
        self.maximumPathDepth = maximumPathDepth
        self.maximumPathNodes = maximumPathNodes
        self.maximumEntries = maximumEntries
        self.maximumPathBytes = maximumPathBytes
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumCompressionRatio = maximumCompressionRatio
    }

    func validate() throws(ZIPError) {
        guard
            maximumPathDepth >= 0, maximumPathNodes >= 0, maximumEntries >= 0, maximumPathBytes >= 0, maximumEntryBytes >= 0,
            maximumTotalBytes >= 0, maximumCompressionRatio.isFinite, maximumCompressionRatio > 0
        else {
            throw ZIPError.invalidArgument("Resource limits must be finite and nonnegative; ratio must be positive")
        }
    }
}

/// The files and directories to extract.
///
/// Selected entries retain their archive paths beneath the destination folder.
public enum ZIPSelection: Sendable {

    /// All entries in the archive.
    case all

    /// Entries matching the supplied paths.
    ///
    /// Use the exact UTF-8 spelling from ``ZIPEntry/path``. A missing path causes extraction to fail
    /// before any output is published.
    case paths(Set<String>)

    /// A directory and everything beneath it.
    ///
    /// The directory may be implied by its children. Both `assets` and `assets/` select the folder,
    /// but neither matches `assets-old`. An ordinary file is not a subtree.
    case subtree(String)
}

/// How to handle an existing destination.
public enum ZIPOverwrite: Sendable {

    /// Fails if anything already exists at the destination.
    case fail

    /// Replaces the existing destination with the completed result.
    ///
    /// The destination must have the same type as the result. Directories are replaced as a whole,
    /// not merged, and symlink destinations are rejected. Failure before publication preserves
    /// the old result. See <doc:SafetyAndLimits> for cleanup behavior.
    case replace
}
