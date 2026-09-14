internal import CMinizip
import Darwin
import Foundation

/// Reads ZIP entries and extracts files from an archive.
///
/// Open a reader with ``withArchive(at:limits:body:)`` and use it inside the closure.
/// Use separate sessions for parallel reads. Calls on one reader must not overlap or call
/// back into it from a callback. File operations fail after the session closes, but copied
/// entry metadata remains usable.
///
/// See <doc:StreamingAndOwnership> for streaming and async usage, and <doc:SafetyAndLimits>
/// for supported formats and extraction rules.
public final class ZIPReader {

    /// The archive's entries in their recorded order.
    ///
    /// Listing entries does not read their file contents. This metadata remains available after
    /// the session closes.
    public let entries: [ZIPEntry]
    private let limits: ZIPLimits
    private let cancellation: ArchiveCancellation?
    private var native: NativeArchive
    private let gate = NSLock()
    private let index: [Data: Int]

    /// Instance-local hooks exercise initialization failures without changing process-wide I/O.
    init(
        at url: URL,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        securePassword: String? = nil,
        afterOpen: (() throws -> Void)? = nil,
        afterClose: (() throws -> Void)? = nil,
    ) throws {
        self.cancellation = cancellation
        try limits.validate()
        native = try NativeArchive(fileDescriptor: FileSystem.openFile(url), writing: false)
        self.limits = limits
        let entries: [ZIPEntry]
        do {
            try afterOpen?()
            try native.prepareCatalog(password: securePassword, limits: limits, cancellation: cancellation)
            entries = try Self.scan(native.pointer, limits: limits, cancellation: cancellation)
            if securePassword != nil, entries.contains(where: { !$0.isDirectory && $0.encryption != .aes256 }) {
                throw ZIPError.unsupported(path: nil, feature: "Secure ZIP requires AES-256 files")
            }
        } catch {
            let primary = error
            do {
                try native.close()
                try afterClose?()
            } catch { throw ZIPError.combined(primary: primary, cleanup: error) }
            throw primary
        }
        self.entries = entries
        index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { (Data($0.element.path.utf8), $0.offset) })
    }

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
    public static func withArchive<T>(at url: URL, limits: ZIPLimits = ZIPLimits(), body: (ZIPReader) throws -> T) throws -> T {
        try withArchive(at: url, limits: limits, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        securePassword: String? = nil,
        body: (ZIPReader) throws -> T,
    ) throws -> T {
        try checkCancellation(cancellation)
        let reader = try ZIPReader(at: url, limits: limits, cancellation: cancellation, securePassword: securePassword)
        return try completing {
            try body(reader)
        } cleanup: {
            try reader.operation { try reader.native.close() }
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
        index[Data(path.utf8)].map { entries[$0] }
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
        try operation {
            guard let entry = entry(at: path) else {
                throw ZIPError.entryNotFound(path)
            }
            var total: Int64 = 0
            try stream(entry, password: password, chunkSize: chunkSize, total: &total) { try consumer(Data(
                bytes: $0.baseAddress!,
                count: $0.count,
            )) }
        }
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
        guard maximumBytes >= 0 else {
            throw ZIPError.invalidArgument("maximumBytes must be nonnegative")
        }
        guard let entry = entry(at: path) else {
            throw ZIPError.entryNotFound(path)
        }
        guard entry.uncompressedSize <= maximumBytes else {
            throw ZIPError.limitExceeded(path)
        }
        var result = Data()
        try read(path: path, password: password) { chunk in
            guard chunk.count <= maximumBytes - result.count else {
                throw ZIPError.limitExceeded(path)
            }
            result.append(chunk)
        }
        return result
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
        try extract(to: destination, selection: selection, overwrite: overwrite, passwordProvider: { _ in password })
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
        try operation {
            try checkCancellation(cancellation)
            let selected = try select(selection)
            let transaction = try OutputTransaction(destination: destination)
            try completing {
                var total: Int64 = 0
                for entry in selected {
                    try checkCancellation(cancellation)
                    let password = entry.encryption == .none ? nil : try passwordProvider(entry)
                    let parts = try EntryPaths.components(entry.path, directory: entry.isDirectory)
                    if entry.isDirectory {
                        let directory = try FileSystem.directory(at: transaction.directory, components: parts[...])
                        try directory.close(operation: "close output directory", path: entry.path)
                        try stream(entry, password: password, chunkSize: 64 * 1024, total: &total) { _ in }
                    } else {
                        let descriptor = try transaction.createFile(entry.path)
                        try descriptor.withCheckedClose(operation: "close output", path: entry.path) { descriptor in
                            try stream(entry, password: password, chunkSize: 64 * 1024, total: &total) {
                                try FileSystem.write($0, to: descriptor, path: entry.path)
                            }
                            guard fsync(descriptor.raw) == 0 else {
                                throw ZIPError.fileSystem(operation: "sync output", path: entry.path, code: errno)
                            }
                        }
                    }
                }
                try checkCancellation(cancellation)
                try transaction.publish(overwrite: overwrite)
            } cleanup: {
                try transaction.cleanup()
            }
        }
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard gate.try() else {
            throw ZIPError.busy
        }
        defer { gate.unlock() }
        guard native.pointer != nil else {
            throw ZIPError.closed
        }
        return try body()
    }

    private func select(_ selection: ZIPSelection) throws -> [ZIPEntry] {
        switch selection {
        case .all:
            return entries
        case let .paths(paths):
            for path in paths where entry(at: path) == nil {
                throw ZIPError.entryNotFound(path)
            }
            let keys = Set(paths.map { Data($0.utf8) })
            return entries.filter { keys.contains(Data($0.path.utf8)) }
        case let .subtree(path):
            let components = try EntryPaths.components(path, directory: true)
            let prefix = Data((components.joined(separator: "/") + "/").utf8)
            let exact = Data(components.joined(separator: "/").utf8)
            let selected = entries.filter {
                let bytes = Data($0.path.utf8)
                return bytes.starts(with: prefix) || ($0.isDirectory && bytes == exact)
            }
            guard !selected.isEmpty else {
                throw ZIPError.entryNotFound(path)
            }
            return selected
        }
    }

    private func stream(
        _ entry: ZIPEntry,
        password: String?,
        chunkSize: Int,
        total: inout Int64,
        consumer: (UnsafeRawBufferPointer) throws -> Void,
    ) throws {
        // Per-callback allocation policy: 64 KiB by default, at most 1 MiB; not a ZIP limit.
        guard (1 ... 1024 * 1024).contains(chunkSize) else {
            throw ZIPError.invalidArgument("chunkSize must be in 1...1048576")
        }
        // APPNOTE 4.4.5: Store = 0, Deflate = 8. minizip resolves AES marker 99
        // to the actual method from the AES extra field before exposing this metadata.
        // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
        guard [0, 8].contains(entry.compressionMethod), entry.encryption != .unsupported else {
            throw ZIPError.unsupported(path: entry.path, feature: "Compression or encryption")
        }
        if entry.encryption == .aes256, password == nil {
            throw ZIPError.backend(operation: .openEncryptedEntry, path: entry.path, status: -108)
        }
        guard entry.uncompressedSize <= limits.maximumTotalBytes - total else {
            throw ZIPError.limitExceeded(entry.path)
        }
        try check(magiczip_seek(native.pointer, entry.position), .seekEntry, path: entry.path)
        // Keep the password buffer alive for the complete native entry lifetime.
        try withPassword(entry.encryption == .none ? nil : password) { password in
            try check(magiczip_read_open(native.pointer, password), .openEntry, path: entry.path)
            var verified = false
            try completing {
                var produced: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    try checkCancellation(cancellation)
                    let count = magiczip_read(native.pointer, &buffer, Int32(buffer.count))
                    guard count >= 0 else {
                        try check(count, .readEntry, path: entry.path)
                        return
                    }
                    if count == 0 {
                        break
                    }
                    guard
                        Int64(count) <= limits.maximumEntryBytes - produced,
                        Int64(count) <= limits.maximumTotalBytes - total,
                        Int64(count) <= entry.uncompressedSize - produced
                    else {
                        throw ZIPError.limitExceeded(entry.path)
                    }
                    produced += Int64(count)
                    total += Int64(count)
                    try buffer.withUnsafeBytes {
                        try consumer(UnsafeRawBufferPointer(rebasing: $0.prefix(Int(count))))
                    }
                }
                verified = true
            } cleanup: {
                try check(magiczip_read_close(native.pointer, verified ? 1 : 0), .verifyAndCloseEntry, path: entry.path)
            }
        }
    }

    private static func scan(
        _ pointer: OpaquePointer?,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
    ) throws -> [ZIPEntry] {
        var count: UInt64 = 0
        try check(magiczip_count(pointer, &count), .countEntries)
        guard count <= limits.maximumEntries else {
            throw ZIPError.limitExceeded("Entry count")
        }
        var entries: [ZIPEntry] = []
        var paths = EntryPaths(maximumDepth: limits.maximumPathDepth, maximumNodes: limits.maximumPathNodes)
        var pathBytes = 0
        var status = magiczip_first(pointer)
        // MZ_END_OF_LIST is normal termination; every other nonzero status is an error.
        while status != -100 {
            try checkCancellation(cancellation)
            try check(status, .enumerateEntries)
            guard entries.count < limits.maximumEntries else {
                throw ZIPError.limitExceeded("Entry count")
            }
            var info = magiczip_info()
            try check(magiczip_metadata(pointer, &info), .readMetadata)
            guard let name = info.name else {
                throw ZIPError.unsafePath("")
            }
            let bytes = Data(bytes: name, count: Int(info.name_length))
            guard let path = String(data: bytes, encoding: .utf8) else {
                throw ZIPError.unsupported(path: nil, feature: "Non-UTF-8 filename")
            }
            guard bytes.count <= limits.maximumPathBytes - pathBytes else {
                throw ZIPError.limitExceeded("Entry-name bytes")
            }
            pathBytes += bytes.count
            let directory = info.directory != 0
            try paths.insert(path, directory: directory)
            // APPNOTE 4.4.2: high byte of made_by identifies UNIX (3) or Darwin (19).
            // For these hosts minizip stores POSIX mode in the upper 16 attribute bits.
            // A zero type is tolerated for producers that omit it; explicit special types are rejected.
            let unixType = (info.attributes >> 16) & UInt32(S_IFMT)
            guard info.symlink == 0, ![3, 19].contains(info.made_by >> 8) || [0, UInt32(S_IFREG), UInt32(S_IFDIR)].contains(unixType)
            else {
                throw ZIPError.unsupported(path: path, feature: "Symlink or special file")
            }
            guard info.disk == 0 else {
                throw ZIPError.unsupported(path: path, feature: "Split archive")
            }
            guard info.compressed_size >= 0, info.uncompressed_size >= 0 else {
                throw ZIPError.backend(operation: .validateSizes, path: path, status: -103)
            }
            guard
                info.uncompressed_size <= limits.maximumEntryBytes,
                Double(info.uncompressed_size) / Double(max(1, info.compressed_size)) <= limits.maximumCompressionRatio
            else {
                throw ZIPError.limitExceeded(path)
            }
            guard !directory || info.uncompressed_size == 0 else {
                throw ZIPError.conflictingPath(path)
            }
            // WinZip AES: general-purpose bit 0 = encrypted, vendor versions 1/2 = AE-1/AE-2,
            // strength code 3 = AES-256 (not a byte count). Other encryption is unsupported.
            // https://www.winzip.com/en/support/aes-encryption/ (AES extra data field)
            let encrypted = info.flags & 1 != 0
            let encryption: ZIPEncryption = encrypted
                ? ([1, 2].contains(info.aes_version) && info.aes_strength == 3 ? .aes256 : .unsupported) : .none
            entries.append(
                ZIPEntry(
                    path: path,
                    isDirectory: directory,
                    compressedSize: info.compressed_size,
                    uncompressedSize: info.uncompressed_size,
                    modificationDate: Date(timeIntervalSince1970: TimeInterval(info.modified)),
                    compressionMethod: info.method,
                    encryption: encryption,
                    crc32: info.crc,
                    position: info.position,
                ),
            )
            status = magiczip_next(pointer)
        }
        guard entries.count == count else {
            throw ZIPError.backend(operation: .validateEntryCount, path: nil, status: -103)
        }
        return entries
    }
}
