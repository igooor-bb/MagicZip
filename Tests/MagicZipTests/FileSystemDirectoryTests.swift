import Darwin
import Foundation
import Testing
@testable import MagicZip

struct FileSystemDirectoryTests {
    @Test(arguments: ["file:", "file:relative/path", "file://localhost", "https://example.invalid/path"], [false, true])
    func `directory lookup rejects URLs without an absolute file path`(rawURL: String, createIntermediates: Bool) throws {
        let url = try #require(URL(string: rawURL))
        do {
            let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
            try opened.close(operation: .closeSourceDirectory, path: url.path)
            Issue.record("Expected an invalid file URL to be rejected")
        } catch ZIPError.invalidArgument {
            // Reject before walking parents: empty and relative URLs may have no root to reach.
        }
    }

    @Test func `relative file path resolved against an absolute base remains supported`() throws {
        try temporaryDirectory { root in
            let base = URL(fileURLWithPath: root.path, isDirectory: true)
            let url = URL(fileURLWithPath: "created/nested", relativeTo: base)
            let opened = try FileSystem.openDirectory(url, createIntermediates: true)
            try opened.close(operation: .closeSourceDirectory, path: url.path)

            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("created/nested").path))
        }
    }

    @Test(arguments: [false, true])
    func `an overlong component is rejected without creating a directory`(createIntermediates: Bool) throws {
        try temporaryDirectory { root in
            let url = root.appendingPathComponent(String(repeating: "x", count: Int(NAME_MAX) + 1))
            do {
                let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
                try opened.close(operation: .closeSourceDirectory, path: url.path)
                Issue.record("Expected an overlong component to be rejected")
            } catch let ZIPError.fileSystem(operation, path, code) {
                #expect(operation == .openDirectory)
                #expect(path == url.path)
                #expect(code == ENAMETOOLONG)
            }

            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `symbolic link cycles fail without creating parents`(createIntermediates: Bool) throws {
        try temporaryDirectory { root in
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "alias")
            let url = alias.appendingPathComponent("nested")

            do {
                let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
                try opened.close(operation: .closeSourceDirectory, path: url.path)
                Issue.record("Expected the symbolic link cycle to be rejected")
            } catch let ZIPError.fileSystem(operation, _, code) {
                #expect(operation == .openDirectory)
                #expect(code == ELOOP)
            }

            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["alias"])
        }
    }

    @Test func `concurrent directory creation converges on the same directory`() async throws {
        let root = canonicalTemporaryDirectory().appendingPathComponent("MagicZip-concurrent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("shared/nested/output")

        let identities = try await withThrowingTaskGroup(of: ino_t.self) { group in
            for _ in 0 ..< 16 {
                group.addTask {
                    let directory = try FileSystem.openDirectory(destination, createIntermediates: true)
                    return try FileIdentity(directory).inode
                }
            }

            var identities: [ino_t] = []
            for try await identity in group {
                identities.append(identity)
            }
            return identities
        }

        #expect(identities.count == 16)
        #expect(Set(identities).count == 1)
    }
}
