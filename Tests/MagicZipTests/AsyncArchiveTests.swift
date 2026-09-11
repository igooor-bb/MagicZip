import Darwin
import Foundation
import Testing
@testable import MagicZip

struct AsyncArchiveTests {
    @MainActor @Test func `async scopes leave the main thread and return owned values`() async throws {
        try await withAsyncDirectory { root in
            let archive = root.appendingPathComponent("archive.zip")
            let count = try await ZIPWriter.withArchiveAsync(at: archive) { writer in
                #expect(!Thread.isMainThread)
                try writer.add(data: Data("hello".utf8), path: "assets/hello", password: "secret")
                try writer.addDirectory(path: "empty")
                return 2
            }
            let entries = try await ZIPReader.withArchiveAsync(at: archive) { reader in
                #expect(!Thread.isMainThread)
                let data = try reader.data(path: "assets/hello", password: "secret")
                #expect(data == Data("hello".utf8))
                try reader.extract(to: root.appendingPathComponent("output"), selection: .subtree("assets"), password: "secret")
                return reader.entries
            }
            #expect(entries.count == count)
            #expect(entries.first?.encryption == .aes256)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("output").path) == ["assets"])
        }
    }

    @Test func `async selection skips corrupt payloads and failed extraction cleans staging`() async throws {
        try await withAsyncDirectory { root in
            let output = root.appendingPathComponent("output")
            try await ZIPReader.withArchiveAsync(at: fixture("selective-corrupt.zip")) { reader in
                try reader.extract(to: output, selection: .paths(["good"]))
            }
            await #expect(throws: ZIPError.self) {
                try await ZIPReader.withArchiveAsync(at: fixture("selective-corrupt.zip")) { reader in
                    try reader.extract(to: output, overwrite: .replace)
                }
            }
            #expect(try Data(contentsOf: output.appendingPathComponent("good")) == Data("selected".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["output"])
        }
    }

    @Test func `async password and limit failures propagate`() async throws {
        await #expect(throws: ZIPError.self) {
            try await ZIPReader.withArchiveAsync(at: fixture("aes2.zip")) { reader in
                try reader.data(path: "secret.txt", password: "wrong")
            }
        }
        await #expect(throws: ZIPError.self) {
            try await ZIPReader.withArchiveAsync(at: fixture("python.zip"), limits: ZIPLimits(maximumEntries: 1)) { _ in }
        }
    }

    @Test func `already cancelled scopes never open files or invoke callbacks`() async {
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let missing = URL(fileURLWithPath: "/MagicZip-missing-parent/archive.zip")
            await #expect(throws: CancellationError.self) {
                try await ZIPWriter.withArchiveAsync(at: missing) { _ in Issue.record("Cancelled writer body ran") }
            }
            await #expect(throws: CancellationError.self) {
                try await ZIPReader.withArchiveAsync(at: missing) { _ in Issue.record("Cancelled reader body ran") }
            }
        }
        await work.value
    }

    @Test(arguments: [false, true])
    func `writer cancellation reaches stream and final publication checkpoints`(afterEntries: Bool) async throws {
        try await withAsyncDirectory { root in
            let archive = root.appendingPathComponent("archive.zip")
            let original = Data("previous destination".utf8)
            try original.write(to: archive)
            let pause = WorkerPause()
            defer { pause.release() }
            let work = Task {
                try await ZIPWriter.withArchiveAsync(at: archive, overwrite: .replace) { writer in
                    if afterEntries {
                        try writer.addDirectory(path: "empty")
                        try pause.wait()
                    } else {
                        try writer.addStream(path: "payload", compression: .store) { maximum in
                            try pause.wait()
                            return Data(repeating: 42, count: maximum)
                        }
                    }
                }
            }
            await pause.started()
            work.cancel()
            pause.release()
            await #expect(throws: CancellationError.self) { try await work.value }
            #expect(try Data(contentsOf: archive) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["archive.zip"])
        }
    }

    @Test func `reader cancellation closes the active entry and archive`() async throws {
        let pause = WorkerPause()
        defer { pause.release() }
        let work = Task {
            try await ZIPReader.withArchiveAsync(at: fixture("python.zip")) { reader in
                try reader.read(path: "hello.txt", chunkSize: 2) { _ in try pause.wait() }
            }
        }
        await pause.started()
        work.cancel()
        pause.release()
        await #expect(throws: CancellationError.self) { try await work.value }
        let bytes = try await ZIPReader.withArchiveAsync(at: fixture("python.zip")) { reader in
            try reader.data(path: "hello.txt")
        }
        #expect(bytes == Data("independent zipfile\n".utf8))
    }

    @Test func `async writer body failure preserves destination and cleans staging`() async throws {
        try await withAsyncDirectory { root in
            let archive = root.appendingPathComponent("archive.zip")
            await #expect(throws: ProbeError.self) {
                try await ZIPWriter.withArchiveAsync(at: archive) { writer in
                    try writer.addDirectory(path: "empty")
                    throw ProbeError.body
                }
            }
            let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(children.isEmpty)
        }
    }

    @Test func `worker continuation preserves simultaneous operation and cleanup errors`() async {
        do {
            try await ArchiveExecutor.shared.run { _ in
                try completing { throw ProbeError.body } cleanup: { throw ProbeError.cleanup }
            }
            Issue.record("Expected both failures")
        } catch let ZIPError.combined(primary, cleanup) {
            #expect(primary as? ProbeError == .body)
            #expect(cleanup as? ProbeError == .cleanup)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func `executor admits at most two simultaneous bodies`() async throws {
        let executor = ArchiveExecutor()
        let activity = WorkerActivity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 12 {
                group.addTask {
                    try await executor.run { _ in
                        activity.begin()
                        defer { activity.end() }
                        // Only dedicated worker threads block; callers remain suspended.
                        usleep(10000)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(activity.peak <= 2)
        #expect(activity.peak > 0)
    }
}

private enum ProbeError: Error {
    case body, cleanup
}

private func withAsyncDirectory(
    isolation _: isolated (any Actor)? = #isolation, _ body: (URL) async throws -> Void,
) async throws {
    let root = canonicalTemporaryDirectory().appendingPathComponent("MagicZipAsyncTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(root)
}

/// An async signal to the test and a bounded synchronous pause on the worker thread.
private final class WorkerPause: Sendable {
    private let signal = AsyncStream<Void>.makeStream()
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() throws {
        signal.continuation.yield(())
        signal.continuation.finish()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw ProbeError.body }
    }

    func started() async {
        for await _ in signal.stream {
            return
        }
    }

    func release() {
        semaphore.signal()
    }
}

private final class WorkerActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
    }
}
