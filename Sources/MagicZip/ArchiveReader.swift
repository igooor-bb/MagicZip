internal import CMinizip
import Darwin
import Foundation

final class ArchiveReader {
    let entries: [ZIPEntry]

    private let limits: ZIPLimits
    private let cancellation: ArchiveCancellation?
    private var native: NativeArchive
    private let gate = NSLock()
    private let index: [Data: Int]

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
            } catch {
                throw ZIPError.combined(primary: primary, cleanup: error)
            }

            throw primary
        }

        self.entries = entries
        index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { (Data($0.element.path.utf8), $0.offset) })
    }

    static func withArchive<T>(
        at url: URL,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        securePassword: String? = nil,
        body: (ArchiveReader) throws -> T,
    ) throws -> T {
        try checkCancellation(cancellation)
        let reader = try ArchiveReader(at: url, limits: limits, cancellation: cancellation, securePassword: securePassword)

        return try completing {
            try body(reader)
        } cleanup: {
            try reader.operation {
                try reader.native.close()
            }
        }
    }

    func entry(at path: String) -> ZIPEntry? {
        index[Data(path.utf8)].map { entries[$0] }
    }

    func read(
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
            try stream(entry, password: password, chunkSize: chunkSize, total: &total) { bytes in
                try bytes.withUnsafeBytes {
                    try consumer(Data($0))
                }
            }
        }
    }

    func data(path: String, password: String? = nil, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
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

    func extract(
        to destination: URL,
        selection: ZIPSelection = .all,
        password: String? = nil,
        overwrite: ZIPOverwrite = .fail,
    ) throws {
        try extract(to: destination, selection: selection, overwrite: overwrite, passwordProvider: { _ in password })
    }

    func extract(
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
                        try directory.close(operation: .closeOutputDirectory, path: entry.path)
                        try stream(entry, password: password, chunkSize: 64 * 1024, total: &total) { _ in }
                    } else {
                        let descriptor = try transaction.createFile(entry.path)
                        try descriptor.withCheckedClose(operation: .closeOutput, path: entry.path) { descriptor in
                            try stream(entry, password: password, chunkSize: 64 * 1024, total: &total) {
                                try $0.withUnsafeBytes {
                                    try FileSystem.write($0, to: descriptor, path: entry.path)
                                }
                            }

                            guard fsync(descriptor.raw) == 0 else {
                                throw ZIPError.fileSystem(operation: .syncOutput, path: entry.path, code: errno)
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
        consumer: (RawSpan) throws -> Void,
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

        if entry.encryption != .none, password == nil {
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
                    let count = try buffer.withUnsafeMutableBytes {
                        try native.read(into: $0, cancellation: cancellation)
                    }
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
                        try consumer(RawSpan(_unsafeBytes: $0).extracting(first: Int(count)))
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
            guard
                info.symlink == 0,
                ![3, 19].contains(info.made_by >> 8) || [0, UInt32(S_IFREG), UInt32(S_IFDIR)].contains(unixType)
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

            // Strong PKWARE encryption is distinct from ZipCrypto and WinZip AES.
            let encryption: ZIPEncryption = if info.flags & 1 == 0 {
                .none
            } else if info.flags & 0x40 != 0 {
                .unsupported
            } else if info.aes_version == 0, info.aes_strength == 0 {
                .zipCrypto
            } else if [1, 2].contains(info.aes_version) {
                switch info.aes_strength {
                case 1:
                    .aes128

                case 2:
                    .aes192

                case 3:
                    .aes256

                default:
                    .unsupported
                }
            } else {
                .unsupported
            }

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
