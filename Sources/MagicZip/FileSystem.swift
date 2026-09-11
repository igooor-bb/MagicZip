import Darwin
import Foundation

struct FileDescriptor: ~Copyable {

    /// Borrowed POSIX value; it must not be closed or transferred while this owner is live.
    let raw: Int32
    init(_ raw: Int32, operation: String, path: String) throws {
        guard raw >= 0 else {
            throw ZIPError.fileSystem(operation: operation, path: path, code: errno)
        }
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
    consuming func withCheckedClose<T: ~Copyable>(
        operation: String,
        path: String,
        _ body: (borrowing FileDescriptor) throws -> T,
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

/// fdopendir consumes an FD only on success; this owner makes that boundary explicit.
private struct DirectoryStream: ~Copyable {
    let pointer: UnsafeMutablePointer<DIR>

    init(_ descriptor: consuming FileDescriptor) throws {
        guard let pointer = fdopendir(descriptor.raw) else {
            let primary = ZIPError.fileSystem(operation: "enumerate directory", path: "", code: errno)
            do { try descriptor.close(operation: "close failed enumeration", path: "") } catch {
                throw ZIPError.combined(primary: primary, cleanup: error)
            }
            throw primary
        }
        _ = descriptor.takeRawValue()
        self.pointer = pointer
    }

    consuming func close() throws {
        let stream = pointer
        discard self
        guard closedir(stream) == 0 else {
            throw ZIPError.fileSystem(operation: "close enumeration", path: "", code: errno)
        }
    }

    consuming func withCheckedClose<T>(_ body: (borrowing DirectoryStream) throws -> T) throws -> T {
        let result: T
        do { result = try body(self) } catch {
            let primary = error
            do { try close() } catch { throw ZIPError.combined(primary: primary, cleanup: error) }
            throw primary
        }
        try close()
        return result
    }

    deinit { _ = closedir(pointer) }
}

struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    init(_ descriptor: borrowing FileDescriptor) throws {
        var info = stat()
        guard fstat(descriptor.raw, &info) == 0 else {
            throw ZIPError.fileSystem(operation: "inspect identity", path: "", code: errno)
        }
        self.init(info)
    }
}

enum FileSystem {
    static func openDirectory(_ url: URL) throws -> FileDescriptor {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw ZIPError.invalidArgument("Expected a local file URL")
        }
        var current = try FileDescriptor(open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC), operation: "open root", path: "/")
        for component in url.path.split(separator: "/") {
            guard component != ".", component != ".." else {
                throw ZIPError.unsafePath(url.path)
            }
            current = try current.withCheckedClose(operation: "close directory component", path: String(component)) {
                try FileDescriptor(
                    openat($0.raw, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                    operation: "open directory without following symlinks",
                    path: url.path,
                )
            }
        }
        return current
    }

    static func openFile(_ url: URL) throws -> FileDescriptor {
        let parent = try openDirectory(url.deletingLastPathComponent())
        return try parent.withCheckedClose(operation: "close source parent", path: url.path) { parent in
            let descriptor = try FileDescriptor(
                openat(parent.raw, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC),
                operation: "open file",
                path: url.path,
            )
            var info = stat()
            guard fstat(descriptor.raw, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                let primary = ZIPError.unsupported(path: url.path, feature: "Only regular source files are supported")
                do { try descriptor.close(operation: "close rejected source", path: url.path) } catch {
                    throw ZIPError.combined(primary: primary, cleanup: error)
                }
                throw primary
            }
            return descriptor
        }
    }

    static func directory(at parent: borrowing FileDescriptor, components: ArraySlice<String>) throws -> FileDescriptor {
        var current = try FileDescriptor(dup(parent.raw), operation: "duplicate directory", path: components.joined(separator: "/"))
        for component in components {
            current = try current.withCheckedClose(operation: "close output parent", path: component) { current in
                if mkdirat(current.raw, component, 0o700) != 0, errno != EEXIST {
                    throw ZIPError.fileSystem(operation: "create directory", path: component, code: errno)
                }
                return try FileDescriptor(
                    openat(current.raw, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                    operation: "open output directory",
                    path: component,
                )
            }
        }
        return current
    }

    static func write(_ bytes: UnsafeRawBufferPointer, to descriptor: borrowing FileDescriptor, path: String) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor.raw, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                throw ZIPError.fileSystem(operation: "write output", path: path, code: errno)
            }
            offset += count
        }
    }

    /// Reopen each component from the pinned root. At most two temporary FDs are live.
    static func reopen(_ root: borrowing FileDescriptor, components: [String]) throws -> FileDescriptor {
        var current = try FileDescriptor(dup(root.raw), operation: "duplicate root", path: "")
        for name in components {
            current = try current.withCheckedClose(operation: "close traversal directory", path: name) {
                try FileDescriptor(
                    openat($0.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC),
                    operation: "reopen directory",
                    path: name,
                )
            }
        }
        return current
    }

    /// A fresh directory stream is used each time; no cookies cross DIR lifetimes.
    static func children(
        _ descriptor: borrowing FileDescriptor,
        maximum: Int,
        byteBudget: Int,
        cancellation: ArchiveCancellation? = nil,
        cleanup: Bool = false,
    ) throws -> [String] {
        let copy = try FileDescriptor(
            openat(descriptor.raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC),
            operation: "open enumeration",
            path: "",
        )
        let stream = try DirectoryStream(copy)
        return try stream.withCheckedClose { stream in
            var names: [String] = []
            var bytes = 0
            while true {
                if !cleanup {
                    try checkCancellation(cancellation)
                }
                errno = 0
                guard let item = readdir(stream.pointer) else {
                    guard errno == 0 else {
                        throw ZIPError.fileSystem(operation: "read directory", path: "", code: errno)
                    }
                    return names
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." {
                    continue
                }
                guard names.count < maximum, name.utf8.count <= byteBudget - bytes else {
                    throw ZIPError.limitExceeded("Pending source names")
                }
                names.append(name)
                bytes += name.utf8.count
                if cleanup, names.count == maximum {
                    return names
                }
            }
        }
    }

    static func remove(parent: borrowing FileDescriptor, name: String) throws {
        // Postorder DFS, with batches removed before re-enumeration. Frames own names, never FDs.
        var components: [String] = []
        var pending: [[String]] = [[name]]
        while !pending.isEmpty {
            if let child = pending[pending.count - 1].popLast() {
                let directory = try reopen(parent, components: components)
                let descend = try directory.withCheckedClose(operation: "close cleanup parent", path: child) { directory in
                    var info = stat()
                    guard fstatat(directory.raw, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                        if errno == ENOENT {
                            return false
                        }
                        throw ZIPError.fileSystem(operation: "inspect cleanup", path: child, code: errno)
                    }
                    if info.st_mode & S_IFMT == S_IFDIR {
                        return true
                    }
                    guard unlinkat(directory.raw, child, 0) == 0 else {
                        throw ZIPError.fileSystem(operation: "remove temporary output", path: child, code: errno)
                    }
                    return false
                }
                if descend {
                    components.append(child)
                    pending.append([])
                }
            } else if components.isEmpty {
                pending.removeLast()
            } else {
                let directory = try reopen(parent, components: components)
                let names = try directory.withCheckedClose(operation: "close cleanup", path: components.last!) {
                    try children($0, maximum: 256, byteBudget: 256 * 255, cleanup: true)
                }
                if !names.isEmpty {
                    pending[pending.count - 1] = names
                    continue
                }
                let child = components.removeLast()
                pending.removeLast()
                let directoryParent = try reopen(parent, components: components)
                try directoryParent.withCheckedClose(operation: "close cleanup parent", path: child) {
                    guard unlinkat($0.raw, child, AT_REMOVEDIR) == 0 else {
                        throw ZIPError.fileSystem(operation: "remove directory", path: child, code: errno)
                    }
                }
            }
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
                operation: "open staging directory",
                path: destination,
            )
        } catch {
            let primary = error
            guard unlinkat(parent.raw, temporaryName, AT_REMOVEDIR) == 0 else {
                throw ZIPError.combined(
                    primary: primary,
                    cleanup: ZIPError.fileSystem(operation: "remove failed staging", path: destination, code: errno),
                )
            }
            throw primary
        }
    }

    func createFile(_ path: String) throws -> FileDescriptor {
        let parts = try EntryPaths.components(path, directory: false)
        let parent = try FileSystem.directory(at: directory, components: parts.dropLast())
        return try parent.withCheckedClose(operation: "close output parent", path: path) { parent in
            try FileDescriptor(
                openat(parent.raw, parts[parts.count - 1], O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600),
                operation: "create output",
                path: path,
            )
        }
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
        guard pendingCleanup else {
            return
        }
        try FileSystem.remove(parent: parent, name: temporaryName)
        pendingCleanup = false
    }

    deinit {
        if pendingCleanup {
            try? FileSystem.remove(parent: parent, name: temporaryName)
        }
    }
}
