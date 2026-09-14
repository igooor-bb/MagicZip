import Foundation
import Testing
@testable import MagicZip

struct SecureArchiveTests {
    @Test(arguments: [ZIPCompression.store, .deflate()])
    func `secure round trip hides names and requires password before body`(compression: ZIPCompression) throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("secure.zip")
            let name = "private-уникальное/report-confidential.txt"
            try SecureZIPWriter.withArchive(at: archive, password: "secret") { writer in
                try writer.add(data: Data("private payload".utf8), path: name, compression: compression)
                try writer.add(data: Data(), path: "empty-secret", compression: compression)
                try writer.addDirectory(path: "hidden-directory")
            }
            let raw = try Data(contentsOf: archive)
            for value in [name, "private payload", "empty-secret", "hidden-directory"] {
                #expect(raw.range(of: Data(value.utf8)) == nil)
            }
            #expect(throws: ZIPError.self) {
                try ZIPReader.withArchive(at: archive) { _ in Issue.record("Ordinary reader accepted Secure ZIP") }
            }
            #expect(throws: ZIPError.self) {
                try SecureZIPReader.withArchive(at: archive, password: "wrong") { _ in Issue.record("Unauthenticated body ran") }
            }
            try SecureZIPReader.withArchive(at: archive, password: "secret") { reader in
                #expect(reader.entries.count == 3)
                #expect(try reader.data(path: name) == Data("private payload".utf8))
                #expect(try reader.data(path: "empty-secret").isEmpty)
                try reader.extract(to: root.appendingPathComponent("out"), selection: .subtree("private-уникальное"))
                #expect(try Data(contentsOf: root.appendingPathComponent("out").appendingPathComponent(name)) ==
                    Data("private payload".utf8))
            }
        }
    }

    @Test func `independent encrypted catalog`() throws {
        try SecureZIPReader.withArchive(at: fixture("secure-independent.zip"), password: "fixture-password") { reader in
            #expect(reader.entries.map(\.path) == ["private/report.txt"])
            let data = try reader.data(path: "private/report.txt")
            #expect(data == Data("independent secure payload".utf8))
        }
    }

    @Test(arguments: ["secure-catalog-corrupt.zip", "secure-catalog-oversized.zip", "secure-count-mismatch.zip", "secure-unsafe-path.zip"])
    func `untrusted catalogs never reach user body`(name: String) {
        #expect(throws: ZIPError.self) {
            try SecureZIPReader.withArchive(at: fixture(name), password: "fixture-password") { _ in
                Issue.record("Invalid catalog reached body")
            }
        }
    }

    @Test func `secure payload failure rolls back extraction`() throws {
        try temporaryDirectory { root in
            let output = root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try Data([42]).write(to: output.appendingPathComponent("old"))
            try SecureZIPReader.withArchive(at: fixture("secure-payload-corrupt.zip"), password: "fixture-password") { reader in
                #expect(reader.entries.count == 1)
                #expect(throws: ZIPError.self) { try reader.extract(to: output, overwrite: .replace) }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: output.path) == ["old"])
            #expect(try Data(contentsOf: output.appendingPathComponent("old")) == Data([42]))
        }
    }

    @Test func `secure metadata honors caller budgets`() {
        #expect(throws: ZIPError.self) {
            try SecureZIPReader.withArchive(
                at: fixture("secure-independent.zip"),
                password: "fixture-password",
                limits: ZIPLimits(maximumEntries: 0),
            ) { _ in
                Issue.record("Count limit bypassed")
            }
        }
        #expect(throws: ZIPError.self) {
            try SecureZIPReader.withArchive(
                at: fixture("secure-independent.zip"),
                password: "fixture-password",
                limits: ZIPLimits(maximumPathDepth: 1),
            ) { _ in
                Issue.record("Path depth limit bypassed")
            }
        }
    }

    @Test func `empty secure archive and ordinary reserved filename`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("empty.zip")
            try SecureZIPWriter.withArchive(at: archive, password: "secret") { _ in }
            try SecureZIPReader.withArchive(at: archive, password: "secret") { reader in
                #expect(reader.entries.isEmpty)
                try reader.extract(to: root.appendingPathComponent("out"))
            }
            let plain = root.appendingPathComponent("plain.zip")
            try ZIPWriter.withArchive(at: plain) { try $0.add(data: Data([1]), path: "__cdcd__") }
            try ZIPReader.withArchive(at: plain) { reader in
                let data = try reader.data(path: "__cdcd__")
                #expect(data == Data([1]))
            }
            #expect(throws: ZIPError.self) { try SecureZIPReader.withArchive(at: plain, password: "secret") { _ in } }
        }
    }

    @Test func `secure cancellation and poisoned writer preserve old output`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("old.zip")
            try Data([42]).write(to: archive)
            #expect(throws: ZIPError.self) {
                try SecureZIPWriter.withArchive(at: archive, password: "secret", overwrite: .replace) { writer in
                    do { try writer.add(data: Data(), path: "../escape") } catch {}
                }
            }
            #expect(try Data(contentsOf: archive) == Data([42]))
            let token = ArchiveCancellation()
            #expect(throws: CancellationError.self) {
                try SecureZIPWriter.withArchive(at: archive, password: "secret", overwrite: .replace, cancellation: token) { writer in
                    try writer.add(data: Data([1]), path: "file")
                    token.cancel()
                }
            }
            #expect(try Data(contentsOf: archive) == Data([42]))
        }
    }

    @Test func `secure asynchronous scope`() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("async.zip")
        try await SecureZIPWriter.withArchiveAsync(at: archive, password: "secret") { writer in
            try writer.add(data: Data([1]), path: "file")
        }
        let bytes = try await SecureZIPReader.withArchiveAsync(at: archive, password: "secret") { try $0.data(path: "file") }
        #expect(bytes == Data([1]))
    }
}
