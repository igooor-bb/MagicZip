import Darwin
import Foundation
import Testing
@testable import MagicZip

/// Run only through test-trees: resource limits belong to this isolated process.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAGICZIP_TREE_PROBE"] == "1"))
struct TreeResourceTests {
    init() throws {
        // This suite is the only suite in the isolated subprocess and executes serially.
        var descriptors = rlimit(rlim_cur: 128, rlim_max: 128)
        var fileSize = rlimit(rlim_cur: 128 * 1024 * 1024, rlim_max: 128 * 1024 * 1024)
        guard setrlimit(RLIMIT_NOFILE, &descriptors) == 0, setrlimit(RLIMIT_FSIZE, &fileSize) == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to set test resource limits"],
            )
        }
    }

    @Test func `self input is rejected under a file size limit`() throws {
        for nested in [false, true] {
            try ReliabilityTests().`overlap rejects before reading transaction and preserves destination`(nested: nested)
        }
        try ReliabilityTests().`legitimate staging-like names and output aliases`()
    }

    @Test(arguments: [24, 96, 192])
    func `deep traversal keeps descriptor usage bounded`(depth: Int) throws {
        try temporaryDirectory { root in
            let monitor = DescriptorMonitor()
            defer { monitor.stop() }
            let archive = root.appendingPathComponent("input.zip")
            let source = root.appendingPathComponent("source")
            let output = root.appendingPathComponent("out.zip")
            let path = String(repeating: "a/", count: depth) + "f"
            try ZIPWriter.withArchive(at: archive) { try $0.add(data: Data([42]), path: path, compression: .store) }
            try ZIPReader.withArchive(at: archive) { try $0.extract(to: source) }
            try ZIPWriter.withArchive(at: output) { try $0.add(directory: source, path: "source", compression: .store) }
            try ZIPReader.withArchive(at: output) { reader in
                let expected = ["source/"] + (1 ... depth).map { "source/" + String(repeating: "a/", count: $0) }
                    + ["source/" + path]
                #expect(reader.entries.map(\.path) == expected)
                let contents = try reader.data(path: "source/" + path)
                #expect(contents == Data([42]))
            }
            // Old destinations are not constrained by the new archive's depth budget.
            let old = root.appendingPathComponent("old")
            try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
            let oldRoot = try FileSystem.openDirectory(old)
            try oldRoot.withCheckedClose(operation: .closeSourceDirectory, path: "old") { descriptor in
                let deep = try FileSystem.directory(at: descriptor, components: Array(repeating: "x", count: 300)[...])
                try deep.close(operation: .closeSourceDirectory, path: "leaf")
            }
            try ZIPReader.withArchive(at: archive) { try $0.extract(to: old, overwrite: .replace) }
            let parent = try FileSystem.openDirectory(root)
            try parent.withCheckedClose(operation: .closeSourceRoot, path: "root") {
                try FileSystem.remove(parent: $0, name: "source")
                try FileSystem.remove(parent: $0, name: "old")
            }
            monitor.stop()
            print("TREE depth=\(depth) baselineFD=\(monitor.baseline) sampledPeakFD=\(monitor.peak)")
            #expect(monitor.peak <= monitor.baseline + 12)
        }
    }

    @Test func `CRC failure cleans depth 96 with 128 descriptors`() throws {
        try temporaryDirectory { root in
            do {
                try ZIPReader.withArchive(at: fixture("deep-corrupt.zip")) { try $0.extract(to: root.appendingPathComponent("out")) }
                Issue.record("Expected CRC failure")
            } catch let ZIPError.backend(_, _, status) {
                #expect(status == -105) // CRC only: no combined EMFILE cleanup error.
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func `cancellation during deep traversal finishes cleanup`(writing: Bool) throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("cancel.zip")
            let path = String(repeating: "a/", count: 96) + "f"
            try ZIPWriter.withArchive(at: archive) { writer in
                var remaining = 64 * 1024 * 1024
                let bytes = Data(repeating: 42, count: 65536)
                try writer.addStream(path: path, compression: .store) { _ in
                    guard remaining > 0 else {
                        return nil
                    }
                    remaining -= bytes.count
                    return bytes
                }
            }
            let source = root.appendingPathComponent("source")
            if writing {
                try ZIPReader.withArchive(at: archive) { try $0.extract(to: source) }
            }
            let token = ArchiveCancellation()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
                    for name in names where name.hasPrefix(".magiczip-") {
                        var info = stat()
                        if
                            stat(root.appendingPathComponent(name + "/" + (writing ? "archive.zip" : path)).path, &info) == 0,
                            info.st_size >= 65536
                        {
                            token.cancel()
                            return
                        }
                    }
                    usleep(1000)
                }
                token.cancel()
            }
            defer { group.wait() }
            #expect(throws: CancellationError.self) {
                if writing {
                    try ZIPWriter.withArchive(at: root.appendingPathComponent("out.zip"), overwrite: .fail, cancellation: token) {
                        try $0.add(directory: source, path: "source", compression: .store)
                    }
                } else {
                    try ZIPReader.withArchive(at: archive, limits: ZIPLimits(), cancellation: token) {
                        try $0.extract(to: root.appendingPathComponent("out"))
                    }
                }
            }
            if writing {
                let parent = try FileSystem.openDirectory(root)
                try parent.withCheckedClose(operation: .closeSourceRoot, path: "root") {
                    try FileSystem.remove(parent: $0, name: "source")
                }
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["cancel.zip"])
        }
    }

    @Test func `wide cleanup processes bounded batches`() throws {
        try temporaryDirectory { root in
            let parent = try FileSystem.openDirectory(root)
            try parent.withCheckedClose(operation: .closeSourceRoot, path: "root") { parent in
                #expect(mkdirat(parent.raw, "wide", 0o700) == 0)
                let wide = try FileSystem.reopen(parent, components: ["wide"])
                try wide.withCheckedClose(operation: .closeSourceDirectory, path: "wide") { wide in
                    for index in 0 ..< 2000 {
                        let file = try FileDescriptor(
                            openat(wide.raw, "f\(index)", O_CREAT | O_WRONLY, 0o600),
                            operation: .createOutput,
                            path: "wide",
                        )
                        try file.close(operation: .closeOutput, path: "wide")
                    }
                }
                try FileSystem.remove(parent: parent, name: "wide")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
}

private final class DescriptorMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var maximum: Int
    let baseline: Int
    private let group = DispatchGroup()

    init() {
        baseline = Self.count()
        maximum = baseline
        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            while true {
                let value = Self.count()
                lock.lock()
                maximum = max(maximum, value)
                let next = running
                lock.unlock()
                if !next {
                    return
                }
                usleep(500)
            }
        }
    }

    var peak: Int {
        lock.withLock { maximum }
    }

    func stop() {
        lock.withLock { running = false }
        group.wait()
    }

    private static func count() -> Int {
        (0 ..< 128).reduce(0) { $0 + (fcntl(Int32($1), F_GETFD) >= 0 ? 1 : 0) }
    }
}
