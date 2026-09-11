internal import CMinizip
import Darwin
import Foundation

/// A scoped, synchronous ZIP reader owning one native archive handle.
///
/// Open a session with ``withArchive(at:limits:body:)``. The class deliberately does not
/// conform to `Sendable`; operations on the same session must not overlap or reenter from
/// a callback. A runtime gate rejects such attempts. Escaped readers reject operations
/// after the scope ends. Use separate sessions for parallel reads.
public final class ZIPReader {

    /// Immutable, owned metadata snapshots in central-directory order.
    /// Access does not move the native cursor or decompress payloads.
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

    /// Opens an archive, runs a synchronous body, and checks archive closure before returning.
    /// - Parameters:
    ///   - url: A regular ZIP file URL. Symlink path components are rejected.
    ///   - limits: Finite metadata and decompression budgets.
    ///   - body: A nonescaping callback borrowing the session's lifetime; do not use it concurrently.
    /// - Returns: The value returned by `body`.
    /// - Throws: ``ZIPError`` for malformed metadata, unsupported paths or limits; callback errors
    ///   propagate. If close also fails, both errors are preserved in ``ZIPError``.
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

    /// Finds an exact UTF-8 path without decompressing any entry.
    /// - Parameter path: The full entry path, including a trailing slash for a directory.
    /// - Returns: An owned snapshot, or `nil`. Lookup remains valid after the scope closes.
    public func entry(at path: String) -> ZIPEntry? {
        index[Data(path.utf8)].map { entries[$0] }
    }

    /// Streams only the requested entry and verifies its length, CRC or AES HMAC before success.
    /// - Parameters:
    ///   - path: Exact UTF-8 entry path.
    ///   - password: AES password; 1...128 UTF-8 bytes without NUL, or `nil` for plaintext.
    ///   - chunkSize: Maximum callback chunk size, in `1...1048576`; defaults to 64 KiB.
    ///   - consumer: Receives owned chunks synchronously. Throw to cancel; do not reenter this reader.
    /// - Throws: ``ZIPError`` for missing/unsupported entries, wrong passwords, integrity or budget
    ///   failures; cancellation and consumer errors propagate. Previously delivered chunks cannot
    ///   be revoked: treat them as provisional until this method returns successfully.
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

    /// Reads one entry into memory, with an additional allocation limit.
    /// - Parameters:
    ///   - path: Exact entry path.
    ///   - password: Optional AES password, subject to the streaming password contract.
    ///   - maximumBytes: Maximum returned data size; defaults to 16 MiB.
    /// - Returns: Owned, integrity-verified data (empty for an empty entry or directory).
    /// - Throws: The errors documented for ``read(path:password:chunkSize:consumer:)`` or a size-limit error.
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

    /// Extracts selected entries into a private directory and publishes the complete result atomically.
    /// - Parameters:
    ///   - destination: Output directory; its parent must exist and contain no symlink components.
    ///   - selection: All entries, exact paths, or a subtree. Unselected payloads are never read.
    ///   - password: Optional password applied to selected encrypted entries.
    ///   - overwrite: Fail if the destination exists, or replace the whole directory atomically.
    /// - Throws: ``ZIPError`` for paths, unsupported features, I/O, integrity, and limits;
    ///   `CancellationError` if the current task is cancelled. Failure before publication removes
    ///   staging output and preserves the previous destination. A post-publication cleanup failure
    ///   is reported, but the new result is already visible. Permissions and timestamps are not restored.
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

    /// Extracts atomically, resolving a password once for each selected encrypted entry.
    /// Plaintext entries do not call the provider. Nil or an incorrect password fails extraction;
    /// provider errors propagate and remove staging output. No password cache or retries are implicit.
    /// Entry metadata is untrusted archive input. The provider must not reenter this reader.
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
        case .all: return entries
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
        guard (1 ... 1024 * 1024).contains(chunkSize) else {
            throw ZIPError.invalidArgument("chunkSize must be in 1...1048576")
        }
        guard [0, 8].contains(entry.compressionMethod), entry.encryption != .unsupported else {
            throw ZIPError.unsupported(path: entry.path, feature: "Compression or encryption")
        }
        if entry.encryption == .aes256, password == nil {
            throw ZIPError.backend(operation: "open encrypted entry", path: entry.path, status: -108)
        }
        guard entry.uncompressedSize <= limits.maximumTotalBytes - total else {
            throw ZIPError.limitExceeded(entry.path)
        }
        try check(magiczip_seek(native.pointer, entry.position), "seek entry", path: entry.path)
        // Keep the password buffer alive for the complete native entry lifetime.
        try withPassword(entry.encryption == .none ? nil : password) { password in
            try check(magiczip_read_open(native.pointer, password), "open entry", path: entry.path)
            var verified = false
            try completing {
                var produced: Int64 = 0
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                while true {
                    try checkCancellation(cancellation)
                    let count = magiczip_read(native.pointer, &buffer, Int32(buffer.count))
                    guard count >= 0 else {
                        try check(count, "read entry", path: entry.path)
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
                try check(magiczip_read_close(native.pointer, verified ? 1 : 0), "verify/close entry", path: entry.path)
            }
        }
    }

    private static func scan(
        _ pointer: OpaquePointer?,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
    ) throws -> [ZIPEntry] {
        var count: UInt64 = 0
        try check(magiczip_count(pointer, &count), "count entries")
        guard count <= limits.maximumEntries else {
            throw ZIPError.limitExceeded("Entry count")
        }
        var entries: [ZIPEntry] = []
        var paths = EntryPaths(maximumDepth: limits.maximumPathDepth, maximumNodes: limits.maximumPathNodes)
        var pathBytes = 0
        var status = magiczip_first(pointer)
        while status != -100 {
            try checkCancellation(cancellation)
            try check(status, "enumerate entries")
            guard entries.count < limits.maximumEntries else {
                throw ZIPError.limitExceeded("Entry count")
            }
            var info = magiczip_info()
            try check(magiczip_metadata(pointer, &info), "read metadata")
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
            let unixType = (info.attributes >> 16) & UInt32(S_IFMT)
            guard info.symlink == 0, ![3, 19].contains(info.made_by >> 8) || [0, UInt32(S_IFREG), UInt32(S_IFDIR)].contains(unixType)
            else {
                throw ZIPError.unsupported(path: path, feature: "Symlink or special file")
            }
            guard info.disk == 0 else {
                throw ZIPError.unsupported(path: path, feature: "Split archive")
            }
            guard info.compressed_size >= 0, info.uncompressed_size >= 0 else {
                throw ZIPError.backend(operation: "validate sizes", path: path, status: -103)
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
            throw ZIPError.backend(operation: "validate entry count", path: nil, status: -103)
        }
        return entries
    }
}
