import CMinizipTestSupport
import Darwin
import Foundation
import Testing
@testable import MagicZip

struct FailureTests {
    @Test func `finalization errors are not lost`() {
        #expect(magiczip_test_finalization_failure(0) == -116)
        #expect(magiczip_test_finalization_failure(1) == -1) // Central-directory stream copy maps I/O errors to MZ_STREAM_ERROR.
    }

    @Test func `native archive close reports file failure`() throws {
        try temporaryDirectory { root in
            let url = root.appendingPathComponent("fault.zip")
            let fd = open(url.path, O_CREAT | O_RDWR | O_EXCL, 0o600)
            #expect(fd >= 0)
            var native = try NativeArchive(fileDescriptor: fd, writing: true)
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
