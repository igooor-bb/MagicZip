import Foundation
import Testing
@testable import MagicZip

struct PasswordAPITests {
    @Test func `common password protects every file including streams and trees`() throws {
        try temporaryDirectory { root in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data([1]).write(to: source.appendingPathComponent("file"))
            let archive = root.appendingPathComponent("common.zip")
            try ZIPWriter.withArchive(at: archive, password: "common") { writer in
                try writer.add(data: Data([2]), path: "data")
                try writer.add(file: source.appendingPathComponent("file"), path: "file")
                try writer.add(directory: source, path: "tree")
                var pending = true
                try writer.addStream(path: "stream") { _ in
                    defer { pending = false }
                    return pending ? Data([3]) : nil
                }
            }
            try ZIPReader.withArchive(at: archive) { reader in
                #expect(reader.entries.filter { !$0.isDirectory }.allSatisfy { $0.encryption == .aes256 })
                try reader.extract(to: root.appendingPathComponent("out"), password: "common")
                #expect(try reader.data(path: "stream", password: "common") == Data([3]))
            }
        }
    }

    @Test func `mixed resolver only sees selected encrypted entries and failures preserve destination`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("mixed.zip")
            try MixedZIPWriter.withArchive(at: archive) { writer in
                try writer.add(data: Data([0]), path: "public", password: nil)
                try writer.add(data: Data([1]), path: "one", password: "first")
                try writer.add(data: Data([2]), path: "two", password: "second")
            }
            try ZIPReader.withArchive(at: archive) { reader in
                let destination = root.appendingPathComponent("out")
                var requested: [String] = []
                try reader.extract(to: destination) { entry in
                    requested.append(entry.path)
                    #expect(throws: ZIPError.self) { try reader.data(path: "public") }
                    return entry.path == "one" ? "first" : "second"
                }
                #expect(requested == ["one", "two"])
                #expect(try Data(contentsOf: destination.appendingPathComponent("two")) == Data([2]))
                #expect(throws: ZIPError.self) {
                    try reader.extract(to: destination, overwrite: .replace) { _ in nil }
                }
                #expect(try Data(contentsOf: destination.appendingPathComponent("two")) == Data([2]))
                requested = []
                try reader.extract(to: root.appendingPathComponent("selected"), selection: .paths(["public", "two"])) { entry in
                    requested.append(entry.path)
                    return "second"
                }
                #expect(requested == ["two"])
                enum ProviderFailure: Error { case stop }
                #expect(throws: ProviderFailure.self) {
                    try reader.extract(to: destination, overwrite: .replace) { _ in throw ProviderFailure.stop }
                }
                #expect(try Data(contentsOf: destination.appendingPathComponent("one")) == Data([1]))
            }
        }
    }
}
