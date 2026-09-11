internal import CMinizip
import Darwin
import Foundation

/// A scoped, synchronous ZIP creator with exclusive native-handle ownership.
///
/// Use ``withArchive(at:overwrite:body:)`` to create a new archive. A session is not
/// `Sendable`; overlapping and reentrant operations are rejected. Any failed add poisons
/// the session, even if its error is caught inside the body, so partial archives cannot be
/// published. Escaped writers are closed after the body. Use separate writers for concurrency.
public final class ZIPWriter {
    private var native: NativeArchive
    private let gate = NSLock()
    private let cancellation: ArchiveCancellation?
    private var failed = false
    private let outputIdentity: FileIdentity
    private let stagingIdentity: FileIdentity
    private let previousIdentity: FileIdentity?
    private var paths = EntryPaths()
    private var entryCount = 0
    private var pathBytes = 0

    private init(
        fileDescriptor: consuming FileDescriptor,
        transaction: OutputTransaction,
        cancellation: ArchiveCancellation?,
    ) throws {
        outputIdentity = try FileIdentity(fileDescriptor)
        stagingIdentity = try FileIdentity(transaction.directory)
        var previous = stat()
        if fstatat(transaction.parent.raw, transaction.destination, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
            previousIdentity = FileIdentity(previous)
        } else {
            guard errno == ENOENT else {
                throw ZIPError.fileSystem(operation: "inspect destination", path: transaction.destination, code: errno)
            }
            previousIdentity = nil
        }
        self.cancellation = cancellation
        native = try NativeArchive(fileDescriptor: fileDescriptor, writing: true)
    }

    /// Creates, finalizes and atomically publishes a ZIP archive.
    /// - Parameters:
    ///   - url: Destination ZIP file; its existing parent must have no symlink path components.
    ///   - overwrite: Fail if a destination exists, or atomically replace a regular file.
    ///   - body: Synchronously adds entries. Do not use the writer concurrently or reenter it.
    /// - Returns: The body's result, after successful finalization and publication.
    /// - Throws: ``ZIPError`` for codec, filesystem, close or publication failures. Body and task
    ///   cancellation errors propagate. Failures before publication preserve any old archive and
    ///   remove staging output. A cleanup failure after publication is reported with the new file visible.
    ///
    /// ```swift
    /// try ZIPWriter.withArchive(at: archiveURL) { writer in
    ///     try writer.add(data: Data("Hello".utf8), path: "hello.txt")
    /// }
    /// ```
    public static func withArchive<T>(at url: URL, overwrite: ZIPOverwrite = .fail, body: (ZIPWriter) throws -> T) throws -> T {
        try withArchive(at: url, overwrite: overwrite, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        overwrite: ZIPOverwrite,
        cancellation: ArchiveCancellation?,
        body: (ZIPWriter) throws -> T,
    ) throws -> T {
        try checkCancellation(cancellation)
        let transaction = try OutputTransaction(destination: url)
        return try completing {
            let descriptor = try transaction.createFile("archive.zip")
            let writer = try ZIPWriter(fileDescriptor: descriptor, transaction: transaction, cancellation: cancellation)
            let result = try completing {
                let result = try body(writer)
                guard !writer.failed else {
                    throw ZIPError.closed
                }
                return result
            } cleanup: {
                try writer.finish()
            }
            try checkCancellation(cancellation)
            try transaction.publish(file: "archive.zip", overwrite: overwrite)
            return result
        } cleanup: {
            try transaction.cleanup()
        }
    }

    /// Adds owned in-memory bytes under the given archive path.
    /// - Parameters:
    ///   - data: Bytes to store; they are consumed synchronously and not retained afterward.
    ///   - path: Relative UTF-8 file path without a trailing slash.
    ///   - compression: Store or Deflate with level `0...9`.
    ///   - password: Optional AES-256 password, 1...128 UTF-8 bytes without NUL.
    ///   - modificationDate: Timestamp; defaults to the time of the call.
    /// - Throws: ``ZIPError`` for invalid/conflicting paths, options, write or finalization errors;
    ///   `CancellationError` if the current task is cancelled. An error invalidates this writer.
    public func add(
        data: Data,
        path: String,
        compression: ZIPCompression = .deflate(),
        password: String? = nil,
        modificationDate: Date = Date(),
    ) throws {
        var offset = 0
        try addStream(path: path, compression: compression, password: password, modificationDate: modificationDate) { maximum in
            guard offset < data.count else {
                return nil
            }
            let end = offset + min(maximum, data.count - offset)
            defer { offset = end }
            let startIndex = data.index(data.startIndex, offsetBy: offset)
            let endIndex = data.index(data.startIndex, offsetBy: end)
            return Data(data[startIndex ..< endIndex])
        }
    }

    /// Streams a regular file into an archive entry without loading the file into memory.
    /// - Parameters:
    ///   - url: Source file; symlinks and nonregular files are rejected, including symlink parents.
    ///   - path: Relative archive path, independent of the source filename.
    ///   - compression: Store or Deflate with level `0...9`.
    ///   - password: Optional AES-256 password.
    /// - Throws: The errors documented for ``addStream(path:compression:password:modificationDate:producer:)``
    ///   and filesystem errors. Source contents must remain unchanged until this call completes.
    public func add(file url: URL, path: String, compression: ZIPCompression = .deflate(), password: String? = nil) throws {
        try operation {
            let descriptor = try FileSystem.openFile(url)
            var info = stat()
            try descriptor.withCheckedClose(operation: "close source", path: url.path) { descriptor in
                guard fstat(descriptor.raw, &info) == 0 else {
                    throw ZIPError.fileSystem(operation: "inspect source", path: url.path, code: errno)
                }
                try appendFile(descriptor, info: info, path: path, compression: compression, password: password)
            }
        }
    }

    /// Adds an explicit empty directory entry.
    /// - Parameters:
    ///   - path: Relative directory path; a trailing slash is added if absent.
    ///   - modificationDate: Directory timestamp recorded in the archive.
    /// - Throws: ``ZIPError`` for invalid/conflicting paths or write/close failures.
    /// Directories are stored without encryption. Cancellation invalidates the writer.
    public func addDirectory(path: String, modificationDate: Date = Date()) throws {
        try operation {
            try append(
                path: path.hasSuffix("/") ? path : path + "/",
                directory: true,
                compression: .store,
                password: nil,
                modificationDate: modificationDate,
            ) { _ in }
        }
    }

    /// Iteratively adds a directory, its files and empty descendants under an archive prefix.
    /// - Parameters:
    ///   - url: Source directory with no symlink path components; the tree must remain stable during this call.
    ///   - path: Nonempty relative archive prefix, such as `assets`.
    ///   - compression: Compression applied to regular files.
    ///   - password: Optional AES password for files; directory entries remain unencrypted.
    /// - Throws: ``ZIPError`` for traversal errors, symlinks, special files, conflicts or write failures.
    /// Enumeration is sorted for consistent entry order; contents and timestamps are not normalized.
    /// Sources overlapping the staging directory, open output, or previous destination (including
    /// hard links) are rejected before reading that object. The old destination remains unchanged.
    /// Tree depth includes the archive prefix and final name, and is limited to 256 components.
    public func add(directory url: URL, path: String, compression: ZIPCompression = .deflate(), password: String? = nil) throws {
        // Public add methods own the gate individually; source-tree enumeration invokes them in order.
        // This outer gate protects the complete recursive operation and uses private helpers below.
        try operation {
            let root = try FileSystem.openDirectory(url)
            try root.withCheckedClose(operation: "close source root", path: path) {
                try appendTree(descriptor: $0, path: path, compression: compression, password: password)
            }
        }
    }

    /// Adds an entry from a bounded, synchronous producer. ZIP64 is enabled for unknown final sizes.
    /// - Parameters:
    ///   - path: Relative UTF-8 file path.
    ///   - compression: Store or Deflate; level must be `0...9`.
    ///   - password: Optional AES-256 password, 1...128 UTF-8 bytes without NUL.
    ///   - modificationDate: Timestamp recorded in the entry.
    ///   - producer: Receives the maximum requested bytes (64 KiB). Return a nonempty `Data` no
    ///     larger than that size, or `nil` at EOF. Throw to cancel; do not reenter this writer.
    /// - Throws: ``ZIPError`` for invalid chunks, paths, options, native writes or finalization;
    ///   producer and cancellation errors propagate. Any error poisons the session.
    /// Payload memory is bounded by the chunk size; central-directory memory grows with entry count,
    /// capped at 100,000 entries, 100,000 distinct path nodes (including implicit directories),
    /// 256 components per path (including the final name), and 16 MiB of UTF-8 names per writer.
    public func addStream(
        path: String,
        compression: ZIPCompression = .deflate(),
        password: String? = nil,
        modificationDate: Date = Date(),
        producer: (Int) throws -> Data?,
    ) throws {
        try operation {
            try append(
                path: path,
                directory: false,
                compression: compression,
                password: password,
                modificationDate: modificationDate,
            ) { consume in
                if let data = try producer(64 * 1024) {
                    try data.withUnsafeBytes(consume)
                }
            }
        }
    }

    private func operation<T>(_ body: () throws -> T) throws -> T {
        guard gate.try() else {
            throw ZIPError.busy
        }
        defer { gate.unlock() }
        guard native.pointer != nil, !failed else {
            throw ZIPError.closed
        }
        do { return try body() } catch { failed = true
            throw error
        }
    }

    private func finish() throws {
        guard gate.try() else {
            throw ZIPError.busy
        }
        defer { gate.unlock() }
        try native.close()
    }

    private func append(
        path: String,
        directory: Bool,
        compression: ZIPCompression,
        password: String?,
        modificationDate: Date,
        producer: (_ consume: (UnsafeRawBufferPointer) throws -> Void) throws -> Void,
    ) throws {
        try checkCancellation(cancellation)
        guard entryCount < 100_000, path.utf8.count <= 16 * 1024 * 1024 - pathBytes else {
            throw ZIPError.limitExceeded("Writer metadata")
        }
        try paths.insert(path, directory: directory)
        entryCount += 1
        pathBytes += path.utf8.count
        let method: Int16
        let level: Int16
        switch compression {
        case .store: method = 0
            level = 0
        case let .deflate(value):
            guard (0 ... 9).contains(value) else {
                throw ZIPError.invalidArgument("Deflate level must be in 0...9")
            }
            method = 8
            level = Int16(value)
        }
        let timestamp = modificationDate.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 315_532_800, timestamp <= 4_354_819_199 else {
            throw ZIPError.invalidArgument("ZIP timestamps must lie between 1980 and 2107")
        }
        try withPassword(password) { password in
            try check(
                magiczip_write_open(native.pointer, path, directory ? 1 : 0, method, level, Int64(timestamp), password),
                "open output entry",
                path: path,
            )
            try completing {
                while true {
                    try checkCancellation(cancellation)
                    var received = false
                    try producer { bytes in
                        guard !received, !bytes.isEmpty, bytes.count <= 64 * 1024 else {
                            throw ZIPError.invalidArgument("Producer must return 1...65536 bytes or nil")
                        }
                        received = true
                        let written = magiczip_write(native.pointer, bytes.baseAddress, Int32(bytes.count))
                        if written < 0 {
                            try check(written, "write entry", path: path)
                        }
                        guard written == bytes.count else {
                            throw ZIPError.backend(operation: "short write", path: path, status: -116)
                        }
                    }
                    if !received {
                        break
                    }
                }
            } cleanup: {
                try check(magiczip_write_close(native.pointer), "finalize entry", path: path)
            }
        }
    }

    private func validateSource(_ info: stat, path: String) throws {
        let identity = FileIdentity(info)
        guard identity != outputIdentity, identity != stagingIdentity, identity != previousIdentity else {
            throw ZIPError.conflictingPath("Source overlaps archive transaction: " + path)
        }
    }

    private func appendFile(
        _ descriptor: borrowing FileDescriptor,
        info: stat,
        path: String,
        compression: ZIPCompression,
        password: String?,
    ) throws {
        try validateSource(info, path: path)
        let storage = StreamBuffer(count: 64 * 1024)
        try storage.withUnsafeMutableBytes { buffer in
            try append(
                path: path,
                directory: false,
                compression: compression,
                password: password,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
            ) { consume in
                var count: Int
                repeat {
                    count = Darwin.read(descriptor.raw, buffer.baseAddress, buffer.count)
                } while
                    count < 0 && errno == EINTR
                guard count >= 0 else {
                    throw ZIPError.fileSystem(operation: "read source", path: path, code: errno)
                }
                if count > 0 {
                    try consume(UnsafeRawBufferPointer(rebasing: buffer.prefix(count)))
                }
            }
        }
    }

    private func appendTree(descriptor: borrowing FileDescriptor, path: String, compression: ZIPCompression, password: String?) throws {
        let prefix = try EntryPaths.components(path, directory: true, maximumDepth: 256)
        var components: [String] = []
        var frames: [[String]] = []
        var pendingCount = 0
        var pendingBytes = 0
        var entering = true
        repeat {
            try checkCancellation(cancellation)
            if entering {
                let directory = try FileSystem.reopen(descriptor, components: components)
                let names = try directory.withCheckedClose(operation: "close source directory", path: path) { directory in
                    var info = stat()
                    guard fstat(directory.raw, &info) == 0 else {
                        throw ZIPError.fileSystem(operation: "inspect source", path: path, code: errno)
                    }
                    try validateSource(info, path: path)
                    try append(
                        path: (prefix + components).joined(separator: "/") + "/",
                        directory: true,
                        compression: .store,
                        password: nil,
                        modificationDate: Date(),
                    ) { _ in }
                    return try FileSystem.children(
                        directory,
                        maximum: 100_000 - pendingCount,
                        byteBudget: 16 * 1024 * 1024 - pendingBytes,
                        cancellation: cancellation,
                    ).sorted(by: >)
                }
                pendingCount += names.count
                pendingBytes += names.reduce(0) { $0 + $1.utf8.count }
                frames.append(names)
                entering = false
            }
            if let name = frames[frames.count - 1].popLast() {
                pendingCount -= 1
                pendingBytes -= name.utf8.count
                guard prefix.count + components.count + 1 <= 256 else {
                    throw ZIPError.limitExceeded("Path components")
                }
                let childPath = (prefix + components + [name]).joined(separator: "/")
                let parent = try FileSystem.reopen(descriptor, components: components)
                let descend = try parent.withCheckedClose(operation: "close source parent", path: childPath) { parent in
                    let child = try FileDescriptor(
                        openat(parent.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
                        operation: "open source child",
                        path: childPath,
                    )
                    return try child.withCheckedClose(operation: "close source child", path: childPath) { child in
                        var info = stat()
                        guard fstat(child.raw, &info) == 0 else {
                            throw ZIPError.fileSystem(operation: "inspect source", path: childPath, code: errno)
                        }
                        try validateSource(info, path: childPath)
                        if info.st_mode & S_IFMT == S_IFDIR {
                            return true
                        }
                        guard info.st_mode & S_IFMT == S_IFREG else {
                            throw ZIPError.unsupported(path: childPath, feature: "Nonregular source file")
                        }
                        try appendFile(child, info: info, path: childPath, compression: compression, password: password)
                        return false
                    }
                }
                if descend {
                    components.append(name)
                    entering = true
                }
            } else {
                frames.removeLast()
                if !components.isEmpty {
                    components.removeLast()
                }
            }
        } while !frames.isEmpty || entering
    }
}
