import Foundation

/// A failure reported by MagicZip, with operation and path context but never a password.
///
/// Native status codes are diagnostic details, not a stable API contract. Callback errors
/// (including `CancellationError`) retain their original type. When cleanup also fails,
/// ``ZIPError/combined(primary:cleanup:)`` preserves both errors.
public indirect enum ZIPError: Error {

    /// A minizip, codec, authentication, or checksum operation failed.
    /// - Parameters:
    ///   - operation: The operation that failed.
    ///   - path: The entry path, when applicable.
    ///   - status: The underlying minizip status code.
    case backend(operation: String, path: String?, status: Int32)

    /// A filesystem operation failed with a POSIX error number.
    case fileSystem(operation: String, path: String, code: Int32)

    /// An operation attempted to use a closed or failed session.
    case closed

    /// Concurrent or reentrant access attempted to use the same session.
    case busy

    /// An option, password length, or stream chunk violated the documented contract.
    case invalidArgument(String)

    /// An entry path is absolute, ambiguous, or contains traversal components.
    case unsafePath(String)

    /// Multiple entries alias the same path, or a file conflicts with a directory.
    case conflictingPath(String)

    /// The archive uses an unsupported entry type, encoding, compression, or encryption.
    case unsupported(path: String?, feature: String)

    /// An advertised or actual size exceeds a configured resource limit.
    case limitExceeded(String)

    /// No entry has the requested exact UTF-8 path.
    case entryNotFound(String)

    /// An operation failed and a subsequent close or cleanup also failed.
    case combined(primary: any Error, cleanup: any Error)
}

/// Compression supported when creating an entry. Values outside `0...9` throw before writing.
public enum ZIPCompression: Sendable, Equatable {

    /// Store bytes without compression.
    case store

    /// Deflate with a zlib level in `0...9`; the default is six.
    /// Level zero uses Store, matching minizip's documented level-zero behavior.
    case deflate(level: Int = 6)
}

/// Encryption used for an entry; credentials are supplied separately to reading/writing methods.
public enum ZIPEncryption: Sendable, Equatable {

    /// An unencrypted entry.
    case none

    /// WinZIP AES with a 256-bit key (AE-1 or AE-2 on read, AE-2 on write).
    case aes256

    /// An encryption variant that can be listed but cannot be read by this version.
    case unsupported
}

/// An immutable metadata snapshot, independent of the reader's current C entry and lifetime.
///
/// These values come from the central directory; payload integrity is checked only when read.
/// Instances are `Sendable` and remain usable after the reader closes.
public struct ZIPEntry: Sendable, Equatable {

    /// The exact UTF-8 archive path; directory names may omit a trailing slash.
    public let path: String

    /// Whether the entry is a directory.
    public let isDirectory: Bool

    /// Compressed byte count, including encryption overhead when present.
    public let compressedSize: Int64

    /// Advertised uncompressed byte count; verified against actual output during reading.
    public let uncompressedSize: Int64

    /// Modification time recorded in the archive; timezone precision depends on its producer.
    public let modificationDate: Date

    /// ZIP compression method number: zero is Store, eight is Deflate.
    public let compressionMethod: UInt16

    /// Encryption classification; unsupported variants fail explicitly when read.
    public let encryption: ZIPEncryption

    /// Central-directory CRC-32. AE-2 normally stores zero and uses HMAC authentication instead.
    public let crc32: UInt32
    let position: Int64
}

/// Resource budgets for a reader. Metadata and selected output are bounded independently.
///
/// Limits must be nonnegative and the ratio must be finite and positive. All advertised entry
/// sizes are checked when opening. The total output budget applies to each read/extract operation,
/// and counts only selected entries. Streaming payload buffers default to 64 KiB.
public struct ZIPLimits: Sendable {

    /// Maximum number of entries, including directories.
    public var maximumEntries: Int

    /// Maximum cumulative UTF-8 entry-name bytes retained in metadata.
    public var maximumPathBytes: Int

    /// Maximum components in a path, including the final file or directory name; defaults to 256.
    public var maximumPathDepth: Int

    /// Maximum distinct path nodes, including implicit directories; defaults to 100,000.
    public var maximumPathNodes: Int

    /// Maximum uncompressed bytes in one entry, advertised and actually produced.
    public var maximumEntryBytes: Int64

    /// Maximum actual output bytes per read or extraction operation.
    public var maximumTotalBytes: Int64

    /// Maximum uncompressed/compressed ratio (using at least one compressed byte).
    public var maximumCompressionRatio: Double

    /// Creates finite resource budgets; validation occurs when opening a reader.
    /// - Parameters:
    ///   - maximumEntries: Entry-count budget; defaults to 100,000.
    ///   - maximumPathBytes: Metadata-name budget; defaults to 16 MiB.
    ///   - maximumEntryBytes: Individual payload budget; defaults to 1 GiB.
    ///   - maximumTotalBytes: Selected output budget; defaults to 4 GiB.
    ///   - maximumCompressionRatio: Expansion-ratio budget; defaults to 1,000.
    ///   - maximumPathDepth: Components per path, including the final name; defaults to 256.
    ///   - maximumPathNodes: Distinct components with parents, including implicit directories; defaults to 100,000.
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

    func validate() throws {
        guard
            maximumPathDepth >= 0, maximumPathNodes >= 0, maximumEntries >= 0, maximumPathBytes >= 0, maximumEntryBytes >= 0,
            maximumTotalBytes >= 0, maximumCompressionRatio.isFinite, maximumCompressionRatio > 0
        else {
            throw ZIPError.invalidArgument("Resource limits must be finite and nonnegative; ratio must be positive")
        }
    }
}

/// The entries to extract, retaining their original paths underneath the destination.
public enum ZIPSelection: Sendable {

    /// Every entry in central-directory order.
    case all

    /// Exact UTF-8 paths. A missing path fails before any output is published.
    case paths(Set<String>)

    /// A directory and its descendants, with component boundaries respected.
    /// The directory may be implicit; either `assets` or `assets/` is accepted.
    case subtree(String)
}

/// Atomic destination publication policy. Existing destinations are never merged.
public enum ZIPOverwrite: Sendable {

    /// Fail if anything already exists at the destination, including a symlink.
    case fail

    /// Atomically replace an existing file or directory of the same type.
    /// A symlink destination is rejected. Failure before publication preserves the old result.
    case replace
}
