import Foundation

public extension ZIPReader {

    /// Opens, uses and closes an archive on a bounded background work queue.
    ///
    /// The calling task suspends while the synchronous body runs off the main thread.
    /// The reader owns its handle for this body only and is not `Sendable`. Do not retain
    /// it, use it concurrently or reenter it from a callback. Return owned `Sendable` values.
    /// The body and stream callbacks cannot suspend and must not access main-actor state.
    /// - Parameters:
    ///   - url: Regular ZIP file URL without symlink path components.
    ///   - limits: Metadata and decompression budgets, identical to synchronous reading.
    ///   - body: Synchronous background work, including listing, streaming or selective extraction.
    /// - Returns: The body's result after the native archive has been closed successfully.
    /// - Throws: The same errors as ``withArchive(at:limits:body:)``, including body errors
    ///   and combined cleanup failures. Task cancellation is forwarded to archive checkpoints.
    ///
    /// Cancellation is cooperative: it cannot interrupt a callback or native call. A queued
    /// cancelled job skips its body when admitted. The await completes only after closure and
    /// cleanup; it does not return early on cancellation. Extraction checks cancellation before
    /// publication. Cancellation racing with or following publication does not roll it back.
    /// At most two async archive bodies run simultaneously across readers and writers.
    /// Task-local values and current-task identity are not propagated into the body.
    ///
    /// ```swift
    /// let entries = try await ZIPReader.withArchiveAsync(at: archiveURL) { reader in
    ///     try reader.extract(to: outputURL, selection: .subtree("assets"))
    ///     return reader.entries
    /// }
    /// ```
    static func withArchiveAsync<T: Sendable>(
        at url: URL,
        limits: ZIPLimits = ZIPLimits(),
        body: @escaping @Sendable (ZIPReader) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, limits: limits, cancellation: cancellation, body: body)
        }
    }
}

/// Only this locked flag crosses from the cancelling task to the synchronous worker.
final class ArchiveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            throw CancellationError()
        }
    }
}

/// Blocking file/codec work stays outside Swift's cooperative executor. Each queued job
/// owns its complete handle lifetime; the continuation resumes exactly once, after cleanup.
final class ArchiveExecutor: Sendable {
    static let shared = ArchiveExecutor()
    private let queue: OperationQueue

    init() {
        queue = OperationQueue()
        queue.name = "MagicZip.archives"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
    }

    func run<T: Sendable>(_ body: @escaping @Sendable (ArchiveCancellation) throws -> T) async throws -> T {
        let cancellation = ArchiveCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    let result = Result {
                        try cancellation.check()
                        return try body(cancellation)
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
