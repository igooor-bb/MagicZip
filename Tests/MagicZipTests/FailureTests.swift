import CMinizipTestSupport
import Darwin
import Foundation
import Testing
@testable import MagicZip

struct FailureTests {
    @Test func `unicode case aliases are rejected`() throws {
        var paths = EntryPaths()
        try paths.insert("Σ/one", directory: false)
        #expect(throws: ZIPError.self) { try paths.insert("ς/two", directory: false) }
    }

    @Test func `finalization errors are not lost`() {
        #expect(magiczip_test_finalization_failure(0) == -116)
        #expect(magiczip_test_finalization_failure(1) == -1) // Central-directory stream copy maps I/O errors to MZ_STREAM_ERROR.
    }

    @Test(arguments: [false, true])
    func `descriptor scope reports close failure and preserves body error`(bodyFails: Bool) throws {
        // Outside the process descriptor range: close deterministically fails without racing
        // another test that might reuse a recently closed descriptor number.
        let descriptor = try FileDescriptor(Int32.max, operation: "test ownership", path: "fixture")
        do {
            try descriptor.withCheckedClose(operation: "close fixture", path: "fixture") { _ in
                if bodyFails {
                    throw CancellationError()
                }
            }
            Issue.record("Expected close failure")
        } catch let ZIPError.combined(primary, cleanup) {
            #expect(bodyFails)
            #expect(primary is CancellationError)
            guard case let ZIPError.fileSystem(operation, path, code) = cleanup else {
                Issue.record("Expected filesystem cleanup error")
                return
            }
            #expect(operation == "close fixture" && path == "fixture" && code == EBADF)
        } catch let ZIPError.fileSystem(operation, path, code) {
            #expect(!bodyFails)
            #expect(operation == "close fixture" && path == "fixture" && code == EBADF)
        }
    }

    @Test func `native archive close reports file failure`() throws {
        try temporaryDirectory { root in
            let url = root.appendingPathComponent("fault.zip")
            let fd = open(url.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
            #expect(fd >= 0)
            let descriptor = try FileDescriptor(fd, operation: "open fault file", path: url.path)
            var native = try NativeArchive(fileDescriptor: descriptor, writing: true)
            let readOnly = open(url.path, O_RDONLY)
            #expect(readOnly >= 0)
            #expect(dup2(readOnly, fd) == fd) // Keep the descriptor occupied while forcing the final write to fail.
            #expect(Darwin.close(readOnly) == 0)
            #expect(throws: ZIPError.self) { try native.close() }
            #expect(native.pointer == nil)
        }
    }

    @Test func `task cancellation cleans staging`() async throws {
        let root = canonicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ZIPReader.withArchive(at: fixture("python.zip")) { reader in
                try reader.extract(to: root.appendingPathComponent("out"))
            }
        }
        await #expect(throws: CancellationError.self) { try await work.value }
        let matches1 = try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
        #expect(matches1)
    }

    @Test func `empty archive and overwrite`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("empty.zip")
            try ZIPWriter.withArchive(at: archive) { _ in }
            try ZIPReader.withArchive(at: archive) { #expect($0.entries.isEmpty) }
            #expect(throws: ZIPError.self) { try ZIPWriter.withArchive(at: archive) { _ in } }
            try ZIPWriter.withArchive(at: archive, overwrite: .replace) { try $0.addDirectory(path: "dir") }
            try ZIPReader.withArchive(at: archive) { #expect($0.entries.map(\.path) == ["dir/"]) }
        }
    }

    @Test func `invalid writer options and paths`() throws {
        try temporaryDirectory { root in
            for path in ["../bad", "/bad", "a\\b", "a//b", "", "a/", "a/../b"] {
                #expect(throws: ZIPError.self) {
                    try ZIPWriter.withArchive(at: root.appendingPathComponent("bad.zip")) { try $0.add(data: Data(), path: path) }
                }
            }
            #expect(throws: ZIPError.self) {
                try ZIPWriter.withArchive(at: root.appendingPathComponent("bad.zip")) {
                    try $0.add(data: Data(), path: "a", compression: .deflate(level: 10))
                }
            }
            #expect(throws: ZIPError.self) {
                try ZIPWriter.withArchive(at: root.appendingPathComponent("bad.zip")) {
                    try $0.add(data: Data(), path: "a", password: "")
                }
            }
            let matches2 = try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
            #expect(matches2)
        }
    }
}
