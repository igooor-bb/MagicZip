import Darwin
import Foundation
import Testing
@testable import MagicZip

struct ArchiveTests {
    @Test(arguments: ["sszip-plain.zip", "sszip-aes.zip"])
    func `independent reference fixtures`(name: String) throws {
        let password = name.contains("aes") ? "interop-password" : nil
        try ZIPReader.withArchive(at: fixture(name)) { reader in
            let data = try reader.data(path: "source.txt", password: password)
            #expect(data == Data("SSZipArchive and MagicZip coexist — Привет!".utf8))
        }
    }

    @Test func `sliced data and bounded producer`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("sliced.zip")
            let original = Data([0, 1, 2, 3])
            try ZIPWriter.withArchive(at: archive) { writer in
                try writer.add(data: original.dropFirst(), path: "slice")
            }
            try ZIPReader.withArchive(at: archive) { reader in
                let actual = try reader.data(path: "slice")
                #expect(actual == Data([1, 2, 3]))
            }
        }
    }

    @Test func `independent plain and ZIP 64`() throws {
        let snapshot = try ZIPReader.withArchive(at: fixture("python.zip")) { reader in
            #expect(reader.entries.count == 7)
            let matches1 = try reader.data(path: "hello.txt") == Data("independent zipfile\n".utf8)
            #expect(matches1)
            let matches2 = try reader.data(path: "assets/привет.txt") == Data("Привет, ZIP!".utf8)
            #expect(matches2)
            let matches3 = try reader.data(path: "zip64.txt") == Data("forced ZIP64".utf8)
            #expect(matches3)
            let matches4 = try reader.data(path: "empty").isEmpty
            #expect(matches4)
            #expect(reader.entry(at: "HELLO.TXT") == nil)
            return try #require(reader.entry(at: "hello.txt"))
        }
        #expect(snapshot.path == "hello.txt")
        #expect(snapshot.uncompressedSize == 20)
    }

    @Test(arguments: ["aes1.zip", "aes2.zip", "aes-store1.zip", "aes-store2.zip"])
    func `independent AES`(name: String) throws {
        try ZIPReader.withArchive(at: fixture(name)) { reader in
            let expected = Data(String(repeating: "independent AES fixture ", count: 4).utf8)
            let matches5 = try reader.data(path: "secret.txt", password: "fixture-password") == expected
            #expect(matches5)
            let matches6 = try reader.data(path: "empty", password: "fixture-password").isEmpty
            #expect(matches6)
            #expect(throws: (any Error).self) { try reader.data(path: "secret.txt", password: "wrong") }
            #expect(throws: (any Error).self) { try reader.data(path: "secret.txt") }
        }
    }

    @Test func `corruption and selective read`() throws {
        try ZIPReader.withArchive(at: fixture("selective-corrupt.zip")) { reader in
            let matches7 = try reader.data(path: "good") == Data("selected".utf8)
            #expect(matches7)
            #expect(throws: (any Error).self) { try reader.data(path: "bad") }
        }
        #expect(throws: (any Error).self) { try ZIPReader.withArchive(at: fixture("truncated.zip")) { _ in } }
        try ZIPReader.withArchive(at: fixture("aes-auth-corrupt.zip")) { reader in
            #expect(throws: (any Error).self) { try reader.data(path: "secret.txt", password: "fixture-password") }
            return ()
        }
    }

    @Test func `unsupported selected only`() throws {
        try ZIPReader.withArchive(at: fixture("unsupported.zip")) { reader in
            #expect(reader.entries.count == 2)
            let matches8 = try reader.data(path: "good") == Data("selected".utf8)
            #expect(matches8)
            #expect(throws: (any Error).self) { try reader.data(path: "bzip2") }
        }
    }

    @Test(arguments: [
        "traversal.zip",
        "absolute.zip",
        "windows.zip",
        "duplicate.zip",
        "case-alias.zip",
        "unicode-alias.zip",
        "prefix-conflict.zip",
        "dot.zip",
        "empty-component.zip",
        "symlink.zip",
    ])
    func `unsafe archives`(name: String) {
        #expect(throws: (any Error).self) { try ZIPReader.withArchive(at: fixture(name)) { _ in } }
    }

    @Test func `writer round trip and lifetime`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("test.zip")
            var escaped: ZIPWriter?
            try ZIPWriter.withArchive(at: archive) { writer in
                escaped = writer
                try writer.add(data: Data("hello".utf8), path: "hello", compression: .store)
                try writer.add(data: Data(repeating: 42, count: 1000), path: "secret", password: "пароль")
                try writer.add(data: Data(), path: "empty", password: "пароль")
                try writer.addDirectory(path: "directory")
            }
            #expect(throws: ZIPError.self) { try escaped?.addDirectory(path: "closed") }
            var escapedReader: ZIPReader?
            try ZIPReader.withArchive(at: archive) { reader in
                escapedReader = reader
                #expect(reader.entries.count == 4)
                let matches9 = try reader.data(path: "hello") == Data("hello".utf8)
                #expect(matches9)
                let matches10 = try reader.data(path: "secret", password: "пароль") == Data(repeating: 42, count: 1000)
                #expect(matches10)
                let matches11 = try reader.data(path: "empty", password: "пароль").isEmpty
                #expect(matches11)
                let matches12 = try reader.data(path: "directory/").isEmpty
                #expect(matches12)
            }
            #expect(throws: ZIPError.self) { try escapedReader?.read(path: "hello") { _ in } }
        }
    }

    @Test func `selective extraction and atomic replace`() throws {
        try temporaryDirectory { root in
            let output = root.appendingPathComponent("output")
            try ZIPReader.withArchive(at: fixture("python.zip")) { reader in
                try reader.extract(to: output, selection: .subtree("assets"))
                let matches13 = try FileManager.default.contentsOfDirectory(atPath: output.path) == ["assets"]
                #expect(matches13)
                let matches14 = try Data(contentsOf: output.appendingPathComponent("assets/привет.txt")) == Data("Привет, ZIP!".utf8)
                #expect(matches14)
                #expect(throws: (any Error).self) { try reader.extract(to: output) }
                try reader.extract(to: output, selection: .paths(["empty", "hello.txt"]), overwrite: .replace)
                #expect(try Set(FileManager.default.contentsOfDirectory(atPath: output.path)) == ["empty", "hello.txt"])
            }
            try ZIPReader.withArchive(at: fixture("selective-corrupt.zip")) { reader in
                #expect(throws: (any Error).self) { try reader.extract(to: output, overwrite: .replace) }
                #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("hello.txt").path))
                try reader.extract(to: output, selection: .paths(["good"]), overwrite: .replace)
                let matches15 = try Data(contentsOf: output.appendingPathComponent("good")) == Data("selected".utf8)
                #expect(matches15)
            }
            let matches16 = try FileManager.default.contentsOfDirectory(atPath: root.path) == ["output"]
            #expect(matches16)
        }
    }

    @Test func `limits and missing selection`() throws {
        #expect(throws: (any Error).self) {
            try ZIPReader.withArchive(at: fixture("python.zip"), limits: ZIPLimits(maximumEntries: 1)) { _ in }
        }
        #expect(throws: (any Error).self) {
            try ZIPReader.withArchive(at: fixture("python.zip"), limits: ZIPLimits(maximumPathBytes: 2)) { _ in }
        }
        #expect(throws: (any Error).self) {
            try ZIPReader.withArchive(at: fixture("python.zip"), limits: ZIPLimits(maximumEntryBytes: 1)) { _ in }
        }
        try temporaryDirectory { root in
            try ZIPReader.withArchive(at: fixture("python.zip"), limits: ZIPLimits(maximumTotalBytes: 5)) { reader in
                #expect(throws: (any Error).self) { try reader.extract(to: root.appendingPathComponent("output")) }
                #expect(throws: (any Error).self) { try reader.data(path: "hello.txt", maximumBytes: 1) }
                #expect(throws: (any Error).self) {
                    try reader.extract(to: root.appendingPathComponent("output"), selection: .paths(["missing"]))
                }
            }
            let matches17 = try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
            #expect(matches17)
        }
    }

    @Test func `source tree and symlink protection`() throws {
        try temporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("file".utf8).write(to: source.appendingPathComponent("a"))
            let archive = root.appendingPathComponent("tree.zip")
            try ZIPWriter.withArchive(at: archive) { writer in
                try writer.add(directory: source, path: "tree")
                try writer.add(file: source.appendingPathComponent("a"), path: "copy")
            }
            try ZIPReader.withArchive(at: archive) { reader in
                #expect(reader.entries.map(\.path) == ["tree/", "tree/a", "tree/empty/", "copy"])
            }
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
            #expect(throws: (any Error).self) {
                try ZIPReader.withArchive(at: archive) { try $0.extract(to: link.appendingPathComponent("escaped")) }
            }
            #expect(throws: (any Error).self) {
                try ZIPReader.withArchive(at: archive) { try $0.extract(to: link, overwrite: .replace) }
            }
            #expect(!FileManager.default.fileExists(atPath: source.appendingPathComponent("escaped").path))
        }
    }

    @Test func `callback failure poisons writer and cleans output`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("archive.zip")
            #expect(throws: (any Error).self) {
                try ZIPWriter.withArchive(at: archive) { writer in
                    do { try writer.addStream(path: "partial") { _ in throw CancellationError() } } catch {}
                    // Catching a failed entry must not allow publication.
                }
            }
            let matches18 = try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
            #expect(matches18)
            try ZIPWriter.withArchive(at: archive) { try $0.add(data: Data([1]), path: "one") }
            let original = try Data(contentsOf: archive)
            #expect(throws: (any Error).self) {
                try ZIPWriter.withArchive(at: archive, overwrite: .replace) { writer in
                    try writer.addStream(path: "bad") { _ in Data() }
                }
            }
            let matches19 = try Data(contentsOf: archive) == original
            #expect(matches19)
        }
    }

    @Test func `reentrancy is rejected and reader recovers after consumer failure`() throws {
        try ZIPReader.withArchive(at: fixture("python.zip")) { reader in
            try reader.read(path: "hello.txt", chunkSize: 2) { _ in
                #expect(throws: ZIPError.self) { try reader.data(path: "hello.txt") }
            }
            #expect(throws: (any Error).self) {
                try reader.read(path: "hello.txt") { _ in throw CancellationError() }
            }
            let matches20 = try reader.data(path: "hello.txt") == Data("independent zipfile\n".utf8)
            #expect(matches20)
        }
    }
}

func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!.resolvingSymlinksInPath()
}

func temporaryDirectory(_ body: (URL) throws -> Void) throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent("MagicZipTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

func canonicalTemporaryDirectory() -> URL {
    let path = realpath(FileManager.default.temporaryDirectory.path, nil)!
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
