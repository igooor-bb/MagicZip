import Darwin
import Foundation

struct FileDescriptor: ~Copyable {
    /// Borrowed POSIX value; it must not be closed or transferred while this owner is live.
    let raw: Int32
    init(_ raw: Int32, operation: String, path: String) throws {
        guard raw >= 0 else { throw ZIPError.fileSystem(operation: operation, path: path, code: errno) }
        self.raw = raw
    }

    /// Transfers responsibility for closing the descriptor to a C API or another owner.
    consuming func takeRawValue() -> Int32 {
        let descriptor = raw
        discard self
        return descriptor
    }

    /// Ends ownership before closing, including the error path: never retry POSIX close.
    consuming func close(operation: String, path: String) throws {
        let descriptor = takeRawValue()
        guard Darwin.close(descriptor) == 0 else {
            throw ZIPError.fileSystem(operation: operation, path: path, code: errno)
        }
    }

    /// Lends the descriptor to synchronous work, then checks close on success and failure.
    consuming func withCheckedClose<T>(
        operation: String, path: String, _ body: (borrowing FileDescriptor) throws -> T,
    ) throws -> T {
        let result: T
        do {
            result = try body(self)
        } catch {
            let primary = error
            do { try close(operation: operation, path: path) } catch {
                throw ZIPError.combined(primary: primary, cleanup: error)
            }
            throw primary
        }
        try close(operation: operation, path: path)
        return result
    }

    deinit { _ = Darwin.close(raw) }
}

enum FileSystem {
    static func openDirectory(_ url: URL) throws -> FileDescriptor {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw ZIPError.invalidArgument("Expected a local file URL") }
        var current = try FileDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), operation: "open root", path: "/")
        for component in url.path.split(separator: "/") {
            guard component != ".", component != ".." else { throw ZIPError.unsafePath(url.path) }
            current = try FileDescriptor(
                openat(current.raw, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                operation: "open directory without following symlinks", path: url.path,
            )
        }
        return current
    }

    static func openFile(_ url: URL) throws -> FileDescriptor {
        let parent = try openDirectory(url.deletingLastPathComponent())
        let descriptor = try FileDescriptor(
            openat(parent.raw, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
            operation: "open file", path: url.path,
        )
        var info = stat()
        guard fstat(descriptor.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ZIPError.unsupported(path: url.path, feature: "Only regular source files are supported")
        }
        return descriptor
    }

    static func directory(at parent: borrowing FileDescriptor, components: ArraySlice<String>) throws -> FileDescriptor {
        var current = try FileDescriptor(dup(parent.raw), operation: "duplicate directory", path: components.joined(separator: "/"))
        for component in components {
            if mkdirat(current.raw, component, 0o700) != 0, errno != EEXIST {
                throw ZIPError.fileSystem(operation: "create directory", path: component, code: errno)
            }
            current = try FileDescriptor(
                openat(current.raw, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                operation: "open output directory", path: component,
            )
        }
        return current
    }

    static func write(_ data: Data, to descriptor: borrowing FileDescriptor, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor.raw, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else { throw ZIPError.fileSystem(operation: "write output", path: path, code: errno) }
                offset += count
            }
        }
    }

    static func remove(parent: borrowing FileDescriptor, name: String) throws {
        var info = stat()
        guard fstatat(parent.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT {
                return
            }
            throw ZIPError.fileSystem(operation: "inspect cleanup", path: name, code: errno)
        }
        let directory = info.st_mode & S_IFMT == S_IFDIR
        if directory {
            let descriptor = try FileDescriptor(
                openat(parent.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), operation: "open cleanup", path: name,
            )
            let copy = dup(descriptor.raw)
            guard copy >= 0 else { throw ZIPError.fileSystem(operation: "duplicate cleanup", path: name, code: errno) }
            guard let stream = fdopendir(copy) else {
                _ = Darwin.close(copy)
                throw ZIPError.fileSystem(operation: "enumerate cleanup", path: name, code: errno)
            }
            try completing {
                while true {
                    errno = 0
                    guard let entry = readdir(stream) else {
                        guard errno == 0 else { throw ZIPError.fileSystem(operation: "read cleanup", path: name, code: errno) }
                        break
                    }
                    let child = withUnsafePointer(to: &entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                    }
                    if child != ".", child != ".." {
                        try remove(parent: descriptor, name: child)
                    }
                }
            } cleanup: {
                guard closedir(stream) == 0 else { throw ZIPError.fileSystem(operation: "close cleanup", path: name, code: errno) }
            }
        }
        guard unlinkat(parent.raw, name, directory ? AT_REMOVEDIR : 0) == 0 else {
            throw ZIPError.fileSystem(operation: "remove temporary output", path: name, code: errno)
        }
    }
}

/// All mutations are anchored to open directory descriptors. A renamed ancestor or a
/// symlink inserted into a path cannot redirect writes outside the opened destination parent.
final class OutputTransaction {
    let parent: FileDescriptor
    let directory: FileDescriptor
    let temporaryName = ".magiczip-" + UUID().uuidString
    let destination: String
    private var pendingCleanup = true

    init(destination url: URL) throws {
        guard url.isFileURL, !url.path.utf8.contains(0), !["", ".", "..", "/"].contains(url.lastPathComponent) else {
            throw ZIPError.invalidArgument("Expected a destination file or directory URL")
        }
        destination = url.lastPathComponent
        parent = try FileSystem.openDirectory(url.deletingLastPathComponent())
        guard mkdirat(parent.raw, temporaryName, 0o700) == 0 else {
            throw ZIPError.fileSystem(operation: "create staging directory", path: destination, code: errno)
        }
        do {
            directory = try FileDescriptor(
                openat(parent.raw, temporaryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                operation: "open staging directory", path: destination,
            )
        } catch {
            _ = unlinkat(parent.raw, temporaryName, AT_REMOVEDIR)
            throw error
        }
    }

    func createFile(_ path: String) throws -> FileDescriptor {
        let parts = try EntryPaths.components(path, directory: false)
        let parent = try FileSystem.directory(at: directory, components: parts.dropLast())
        return try FileDescriptor(
            openat(parent.raw, parts[parts.count - 1], O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
            operation: "create output", path: path,
        )
    }

    func publish(file: String? = nil, overwrite: ZIPOverwrite) throws {
        try checkCancellation()
        let sourceParent = file == nil ? parent.raw : directory.raw
        let sourceName = file ?? temporaryName
        var existing = stat()
        let exists = fstatat(parent.raw, destination, &existing, AT_SYMLINK_NOFOLLOW) == 0
        if !exists, errno != ENOENT {
            throw ZIPError.fileSystem(operation: "inspect destination", path: destination, code: errno)
        }
        if exists {
            let wanted = file == nil ? S_IFDIR : S_IFREG
            guard existing.st_mode & S_IFMT == wanted else {
                throw ZIPError.conflictingPath(destination)
            }
        }
        let flags = overwrite == .replace && exists ? UInt32(RENAME_SWAP) : UInt32(RENAME_EXCL)
        guard renameatx_np(sourceParent, sourceName, parent.raw, destination, flags) == 0 else {
            throw ZIPError.fileSystem(operation: "publish output", path: destination, code: errno)
        }
        if file == nil, !exists {
            pendingCleanup = false
        }
        // After a swap the old destination is staged, so cleanup never traverses its symlinks.
        // A cleanup error is reported even though the new destination is already published.
    }

    func cleanup() throws {
        guard pendingCleanup else { return }
        try FileSystem.remove(parent: parent, name: temporaryName)
        pendingCleanup = false
    }

    deinit {
        if pendingCleanup {
            try? FileSystem.remove(parent: parent, name: temporaryName)
        }
    }
}
