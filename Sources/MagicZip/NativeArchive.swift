internal import CMinizip
import Foundation

/// The noncopyable owner expresses the C handle's single lifetime internally. Public scoped
/// reference sessions support ergonomic throwing callbacks without exposing pointer ownership.
struct NativeArchive: ~Copyable {
    var pointer: OpaquePointer?

    init(fileDescriptor: consuming FileDescriptor, writing: Bool) throws {
        var pointer: OpaquePointer?
        // The adapter consumes the descriptor on every path, including failure to open.
        try check(magiczip_open(fileDescriptor.takeRawValue(), writing ? 1 : 0, &pointer), .openArchive)
        self.pointer = pointer
    }

    mutating func close() throws {
        try check(magiczip_close(&pointer), .closeArchive)
    }

    deinit {
        // Exception fallback only. Successful public scopes always call throwing close().
        var pointer = pointer
        _ = magiczip_close(&pointer)
    }
}

/// A single bounded allocation; borrowed bytes must not outlive the synchronous callback.
struct StreamBuffer: ~Copyable {
    private let bytes: UnsafeMutableRawBufferPointer

    init(count: Int) {
        // Conservative buffer alignment, not a ZIP/AES format requirement.
        bytes = .allocate(byteCount: count, alignment: 16)
    }

    borrowing func withUnsafeMutableBytes<T>(_ body: (UnsafeMutableRawBufferPointer) throws -> T) rethrows -> T {
        try body(bytes)
    }

    deinit { bytes.deallocate() }
}

/// Status values retain minizip meanings across the private C bridge: -100 end-of-list,
/// -103 invalid format, -107 absent item, -108 password required, -116 write failure.
/// https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz.h
func check(_ status: Int32, _ operation: ZIPBackendOperation, path: String? = nil) throws {
    guard status == 0 else {
        throw ZIPError.backend(operation: operation, path: path, status: status)
    }
}

func withPassword<T>(_ password: String?, _ body: (UnsafePointer<CChar>?) throws -> T) throws -> T {
    guard let password else {
        return try body(nil)
    }
    // minizip caps strlen(password) at MZ_AES_PW_LENGTH_MAX (128 bytes); NUL would truncate it.
    // Rejecting an empty password is our API policy, not an AES requirement.
    // https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz_strm_wzaes.c
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

func checkCancellation(_ cancellation: ArchiveCancellation? = nil) throws {
    try cancellation?.check()
    try Task<Never, Never>.checkCancellation()
}

struct EntryPaths {
    private struct Key: Hashable {
        let parent: Int
        let component: String
    }

    private struct Node {
        let spelling: Data
        var directory: Bool
        var explicit: Bool
    }

    private var nodes: [Node] = []
    private var children: [Key: Int] = [:]
    let maximumDepth: Int
    let maximumNodes: Int

    init(maximumDepth: Int = 256, maximumNodes: Int = 100_000) {
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
    }

    static func components(_ path: String, directory: Bool, maximumDepth: Int = Int.max) throws -> [String] {
        // ZIP filename length is a 16-bit byte count, even in ZIP64 (APPNOTE 4.4.10).
        // https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
        guard path.utf8.count <= Int(UInt16.max) else {
            throw ZIPError.unsafePath(path)
        }
        let name = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        // 47 is the UTF-8 byte for "/"; count before allocating strings or Unicode folding.
        let depth = name.utf8.reduce(1) { $1 == 47 ? $0 + 1 : $0 }
        guard depth <= maximumDepth else {
            throw ZIPError.limitExceeded("Path components")
        }
        // The 255-byte component cap below is our filesystem-portability policy, not a ZIP field limit.
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard
            !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
            !name.utf8.contains(0),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 })
        else {
            throw ZIPError.unsafePath(path)
        }
        return parts
    }

    mutating func insert(_ path: String, directory: Bool) throws {
        let parts = try Self.components(path, directory: directory, maximumDepth: maximumDepth)
        var parent = -1
        for (offset, part) in parts.enumerated() {
            let last = offset == parts.count - 1
            let key = Key(parent: parent, component: part.folding(
                options: .caseInsensitive,
                locale: Locale(identifier: "en_US_POSIX"),
            ).precomposedStringWithCanonicalMapping)
            let spelling = Data(part.utf8)
            if let id = children[key] {
                guard
                    nodes[id].spelling == spelling, nodes[id].directory,
                    !last || (directory && !nodes[id].explicit)
                else {
                    throw ZIPError.conflictingPath(path)
                }
                if last {
                    nodes[id].explicit = true
                }
                parent = id
            } else {
                guard nodes.count < maximumNodes else {
                    throw ZIPError.limitExceeded("Path nodes")
                }
                let id = nodes.count
                nodes.append(Node(spelling: spelling, directory: !last || directory, explicit: last))
                children[key] = id
                parent = id
            }
        }
    }
}
