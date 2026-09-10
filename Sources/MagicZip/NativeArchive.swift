internal import CMinizip
import Foundation

/// The noncopyable owner expresses the C handle's single lifetime internally. Public scoped
/// reference sessions support ergonomic throwing callbacks without exposing pointer ownership.
struct NativeArchive: ~Copyable {
    var pointer: OpaquePointer?

    init(fileDescriptor: Int32, writing: Bool) throws {
        var pointer: OpaquePointer?
        try check(magiczip_open(fileDescriptor, writing ? 1 : 0, &pointer), "open archive")
        self.pointer = pointer
    }

    mutating func close() throws {
        try check(magiczip_close(&pointer), "close archive")
    }

    deinit {
        // Exception fallback only. Successful public scopes always call throwing close().
        var pointer = pointer
        _ = magiczip_close(&pointer)
    }
}

func check(_ status: Int32, _ operation: String, path: String? = nil) throws {
    guard status == 0 else { throw ZIPError.backend(operation: operation, path: path, status: status) }
}

func withPassword<T>(_ password: String?, _ body: (UnsafePointer<CChar>?) throws -> T) throws -> T {
    guard let password else { return try body(nil) }
    guard !password.utf8.contains(0), (1 ... 128).contains(password.utf8.count) else {
        throw ZIPError.invalidArgument("Passwords must contain 1...128 UTF-8 bytes and no NUL")
    }
    return try password.withCString(body)
}

/// Preserve the operation error if finalization fails as well.
func completing<T>(_ body: () throws -> T, cleanup: () throws -> Void) throws -> T {
    let value: T
    do { value = try body() } catch {
        let primary = error
        do { try cleanup() } catch { throw ZIPError.combined(primary: primary, cleanup: error) }
        throw primary
    }
    try cleanup()
    return value
}

func checkCancellation() throws {
    try Task<Never, Never>.checkCancellation()
}

struct EntryPaths {
    private var files = Set<String>()
    private var directories = Set<String>()
    private var explicit = Set<String>()
    private var spellings: [String: Data] = [:]

    static func components(_ path: String, directory: Bool) throws -> [String] {
        let name = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.utf8.contains(0), path.utf8.count <= Int(UInt16.max),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else { throw ZIPError.unsafePath(path) }
        return parts
    }

    mutating func insert(_ path: String, directory: Bool) throws {
        let parts = try Self.components(path, directory: directory)
        // Conservatively reject case and canonical Unicode aliases on every supported filesystem.
        let canonical = parts.map { $0.precomposedStringWithCanonicalMapping.lowercased() }
        for count in 1 ... canonical.count {
            let key = canonical.prefix(count).joined(separator: "/")
            let spelling = Data(parts.prefix(count).joined(separator: "/").utf8)
            if let previous = spellings[key], previous != spelling {
                throw ZIPError.conflictingPath(path)
            }
            spellings[key] = spelling
        }
        let full = canonical.joined(separator: "/")
        guard !explicit.contains(full), !files.contains(full), directory || !directories.contains(full) else {
            throw ZIPError.conflictingPath(path)
        }
        for count in 1 ..< canonical.count {
            let parent = canonical.prefix(count).joined(separator: "/")
            guard !files.contains(parent) else { throw ZIPError.conflictingPath(path) }
            directories.insert(parent)
        }
        explicit.insert(full)
        if directory {
            directories.insert(full)
        } else {
            files.insert(full)
        }
    }
}
