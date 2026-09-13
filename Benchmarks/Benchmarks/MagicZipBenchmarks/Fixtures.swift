import Foundation
import MagicZip

enum FixtureError: Error {
    case mismatch(String)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else {
        throw FixtureError.mismatch(message)
    }
}

enum ArchiveVariant: String, CaseIterable {
    case store, deflate, storeAES = "store-aes", deflateAES = "deflate-aes"

    var compression: ZIPCompression {
        switch self {
        case .store, .storeAES:
            .store
        case .deflate, .deflateAES:
            .deflate(level: 6)
        }
    }

    var password: String? {
        switch self {
        case .store, .deflate:
            nil
        case .storeAES, .deflateAES:
            "magiczip-benchmark-password"
        }
    }
}

/// SplitMix64, fixed seed and little-endian output: fixtures do not depend on Swift's random generator.
struct FixtureGenerator {
    var state: UInt64 = 42

    mutating func bytes(count: Int) -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            for _ in 0 ..< min(8, count - data.count) {
                data.append(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
        return data
    }
}

final class ArchiveFixture {
    enum Workload: String, CaseIterable {
        case text, random, tree
    }

    let workload: Workload
    let variant: ArchiveVariant
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("magiczip-benchmark-\(UUID().uuidString)")
    var source: URL {
        root.appendingPathComponent("source")
    }

    var archive: URL {
        root.appendingPathComponent("fixture.zip")
    }

    var output: URL {
        root.appendingPathComponent("output")
    }

    var files: [String: URL] = [:]
    var inputBytes: Int {
        workload == .tree ? 2000 * 1024 : 64 * 1024 * 1024
    }

    init(_ workload: Workload, _ variant: ArchiveVariant) {
        self.workload = workload
        self.variant = variant
    }

    func prepare(needsArchive: Bool) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            var generator = FixtureGenerator()
            if workload == .tree {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
                for directory in 0 ..< 20 {
                    let name = String(format: "d%02d", directory)
                    let folder = source.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    for index in 0 ..< 100 {
                        let fileName = String(format: "f%03d.bin", index)
                        let file = folder.appendingPathComponent(fileName)
                        try generator.bytes(count: 1024).write(to: file)
                        files["tree/\(name)/\(fileName)"] = file
                    }
                }
            } else {
                try Data().write(to: source)
                let handle = try FileHandle(forWritingTo: source)
                try completingFile(handle) {
                    // Numbered text records compress well without exceeding the default expansion-ratio budget.
                    for index in 0 ..< 1024 {
                        let chunk: Data
                        if workload == .random {
                            chunk = generator.bytes(count: 65536)
                        } else {
                            var text = Data()
                            var line = 0
                            while text.count < 65536 {
                                let record = "record=\(index * 1024 + line) asset=images/catalog/item.png enabled=true locale=en_US\n"
                                text.append(contentsOf: record.utf8)
                                line += 1
                            }
                            chunk = Data(text.prefix(65536))
                        }
                        try handle.write(contentsOf: chunk)
                    }
                }
                files["payload.bin"] = source
            }
            if needsArchive {
                try write(to: archive)
                try verifyArchive(at: archive)
            }
        } catch {
            try cleanup()
            throw error
        }
    }

    func write(to url: URL) throws {
        try ZIPWriter.withArchive(at: url, password: variant.password) { writer in
            if workload == .tree {
                try writer.add(directory: source, path: "tree", compression: variant.compression)
            } else {
                try writer.add(file: source, path: "payload.bin", compression: variant.compression)
            }
        }
    }

    func removeOutput() throws {
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    func expectedPaths(for selected: [String: URL]) -> Set<String> {
        var paths = Set(selected.keys)
        for path in selected.keys {
            let components = path.split(separator: "/")
            for depth in 1 ..< components.count {
                paths.insert(components.prefix(depth).joined(separator: "/") + "/")
            }
        }
        return paths
    }

    func verifyArchive(at url: URL) throws {
        try ZIPReader.withArchive(at: url) { reader in
            try require(Set(reader.entries.map(\.path)) == expectedPaths(for: files), "archive paths")
            for (path, file) in files {
                let handle = try FileHandle(forReadingFrom: file)
                try completingFile(handle) {
                    try reader.read(path: path, password: variant.password) { chunk in
                        try require(handle.read(upToCount: chunk.count) == chunk, "archive content: \(path)")
                    }
                    try require(handle.read(upToCount: 1)?.isEmpty != false, "archive length: \(path)")
                }
            }
        }
    }

    func verifyExtraction(files selected: [String: URL]) throws {
        var paths = Set<String>()
        /// Explicit recursion propagates directory-listing errors; fixture depth is bounded at three levels.
        func visit(_ directory: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                let path = prefix + url.lastPathComponent + (isDirectory ? "/" : "")
                paths.insert(path)
                if isDirectory {
                    try visit(url, prefix: path)
                }
            }
        }
        try visit(output, prefix: "")
        try require(paths == expectedPaths(for: selected), "extracted paths")
        for (path, file) in selected {
            try require(
                FileManager.default.contentsEqual(atPath: file.path, andPath: output.appendingPathComponent(path).path),
                "extracted content: \(path)",
            )
        }
    }
}

func completingFile(_ handle: FileHandle, body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        try handle.close()
        throw error
    }
    try handle.close()
}
