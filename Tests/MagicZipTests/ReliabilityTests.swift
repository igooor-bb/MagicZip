import Darwin
import Foundation
import Testing
@testable import MagicZip

struct ReliabilityTests {
    @Test(arguments: ["directory-no-slash.zip", "directory-slash.zip", "directory-implicit.zip"])
    func `subtrees preserve directory spelling and component boundaries`(fixtureName: String) throws {
        for argument in ["assets", "assets/"] {
            try temporaryDirectory { root in
                try ZIPReader.withArchive(at: fixture(fixtureName)) { reader in
                    let output = root.appendingPathComponent("out")
                    try reader.extract(to: output, selection: .subtree(argument))
                    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("assets").path))
                    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("assets-old").path))
                    #expect(throws: ZIPError.self) { try reader.extract(to: output, selection: .subtree("Assets")) }
                    if fixtureName == "directory-no-slash.zip" {
                        #expect(reader.entry(at: "assets")?.isDirectory == true)
                        #expect(reader.entry(at: "assets/") == nil)
                    }
                }
            }
        }
    }

    @Test func `file is not a subtree and Unicode selection is exact`() throws {
        try temporaryDirectory { root in
            try ZIPReader.withArchive(at: fixture("directory-file.zip")) { reader in
                #expect(throws: ZIPError.self) { try reader.extract(to: root.appendingPathComponent("out"), selection: .subtree("assets")) }
            }
            try ZIPReader.withArchive(at: fixture("directory-unicode.zip")) { reader in
                try reader.extract(to: root.appendingPathComponent("out"), selection: .subtree("ресурсы/"))
                #expect(throws: ZIPError.self) {
                    try reader.extract(to: root.appendingPathComponent("wrong"), selection: .subtree("Ресурсы"))
                }
            }
        }
    }

    @Test func `path budgets include leaves and implicit nodes`() throws {
        var paths = EntryPaths(maximumDepth: 3, maximumNodes: 4)
        try paths.insert("a/b/f", directory: false)
        try paths.insert("a/b/", directory: true)
        try paths.insert("a/g", directory: false)
        #expect(throws: ZIPError.self) { try paths.insert("h", directory: false) }
        var shallow = EntryPaths(maximumDepth: 2)
        #expect(throws: ZIPError.self) { try shallow.insert("a/b/f", directory: false) }
        for limits in [ZIPLimits(maximumPathDepth: 96), ZIPLimits(maximumPathNodes: 96)] {
            do {
                try ZIPReader.withArchive(at: fixture("deep-valid.zip"), limits: limits) { _ in Issue.record("Unexpected open") }
            } catch ZIPError.limitExceeded {} // Require the typed limit error, not an arbitrary failure.
        }
        try ZIPReader.withArchive(at: fixture("deep-valid.zip"), limits: ZIPLimits(maximumPathDepth: 97, maximumPathNodes: 97)) {
            #expect($0.entries.count == 1)
        }
        try temporaryDirectory { root in
            do {
                try ZIPWriter.withArchive(at: root.appendingPathComponent("out.zip")) {
                    try $0.add(data: Data(), path: String(repeating: "a/", count: 256) + "f")
                }
                Issue.record("Expected depth failure")
            } catch ZIPError.limitExceeded {}
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func `flat registry accepts long paths and preserves implicit aliases`() throws {
        for depth in [2000, 4000, 8000] {
            var paths = EntryPaths(maximumDepth: depth + 1)
            try paths.insert(String(repeating: "a/", count: depth) + "f", directory: false)
        }
        for (first, second) in [("Σ/a", "ς/b"), ("é/a", "e\u{301}/b")] {
            var paths = EntryPaths()
            try paths.insert(first, directory: false)
            #expect(throws: ZIPError.self) { try paths.insert(second, directory: false) }
        }
    }

    @Test(arguments: [false, true])
    func `scan errors preserve checked close failure`(cancel: Bool) throws {
        var closed = 0
        let token = ArchiveCancellation()
        do {
            _ = try ZIPReader(
                at: fixture("python.zip"),
                limits: ZIPLimits(maximumEntries: cancel ? 100_000 : 0),
                cancellation: token,
                afterOpen: {
                    if cancel {
                        token.cancel()
                    }
                },
                afterClose: { closed += 1
                    throw ZIPError.backend(operation: "injected close", path: nil, status: -116)
                },
            )
            Issue.record("Expected initialization failure")
        } catch let ZIPError.combined(primary, cleanup) {
            if cancel {
                #expect(primary is CancellationError)
            } else {
                guard case ZIPError.limitExceeded = primary else {
                    Issue.record("Lost scan error")
                    return
                }
            }
            guard case ZIPError.backend = cleanup else {
                Issue.record("Lost close error")
                return
            }
        }
        #expect(closed == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAGICZIP_TREE_PROBE"] == "1"), arguments: [false, true])
    func `overlap rejects before reading transaction and preserves destination`(nested: Bool) throws {
        try temporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            let folder = nested ? source.appendingPathComponent("child") : source
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent("result.zip")
            let old = Data("old result".utf8)
            try old.write(to: destination)
            #expect(throws: ZIPError.self) {
                try ZIPWriter.withArchive(at: destination, overwrite: .replace) { writer in
                    try writer.add(data: Data(repeating: 7, count: 100_000), path: "already-written", compression: .store)
                    try writer.add(directory: source, path: "source")
                }
            }
            #expect(try Data(contentsOf: destination) == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["result.zip"])
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAGICZIP_TREE_PROBE"] == "1"))
    func `legitimate staging-like names and output aliases`() throws {
        try temporaryDirectory { root in
            let source = root.appendingPathComponent(".magiczip-user")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("user".utf8).write(to: source.appendingPathComponent("f"))
            let output = root.appendingPathComponent("out.zip")
            try ZIPWriter.withArchive(at: output) { try $0.add(directory: source, path: "user") }
            try ZIPReader.withArchive(at: output) { #expect($0.entries.map(\.path) == ["user/", "user/f"]) }
            #expect(throws: ZIPError.self) {
                try ZIPWriter.withArchive(at: output, overwrite: .replace) { writer in
                    try writer.add(data: Data(repeating: 7, count: 100_000), path: "already-written", compression: .store)
                    let staging = try #require(FileManager.default.contentsOfDirectory(atPath: root.path)
                        .first { $0.hasPrefix(".magiczip-") && $0 != ".magiczip-user" })
                    let alias = root.appendingPathComponent("alias")
                    try FileManager.default.linkItem(at: root.appendingPathComponent(staging + "/archive.zip"), to: alias)
                    try writer.add(file: alias, path: "self")
                }
            }
        }
    }

    @Test func `public chunks remain independently owned`() throws {
        try temporaryDirectory { root in
            let payload = Data((0 ..< 200_000).map { UInt8(truncatingIfNeeded: $0 / 1024) })
            let input = root.appendingPathComponent("input")
            let archive = root.appendingPathComponent("out.zip")
            try payload.write(to: input)
            try ZIPWriter.withArchive(at: archive) { try $0.add(file: input, path: "f") }
            var chunks: [Data] = []
            try ZIPReader.withArchive(at: archive) { try $0.read(path: "f", chunkSize: 1024) { chunks.append($0) } }
            #expect(chunks.reduce(into: Data()) { $0.append($1) } == payload)
        }
    }
}
