import Foundation

public extension ZIPReader {

    /// Reads an archive on a background queue while the calling task waits asynchronously.
    ///
    /// Use the reader only inside the closure. Return results such as `Data` or `[ZIPEntry]`
    /// to use them afterward. The closure runs synchronously and cannot access main-actor state.
    ///
    /// - Parameters:
    ///   - url: The archive file. Its path must not contain symlinks.
    ///   - limits: Limits on archive metadata and decompressed data.
    ///   - body: The synchronous work to perform with this reader.
    /// - Returns: The closure's result after the archive has been closed.
    /// - Throws: A reading, callback or cancellation error. Additional cleanup errors are preserved.
    ///
    /// Cancellation does not interrupt an active callback. The await completes only after closure
    /// and cleanup. Already published output is not rolled back by cancellation.
    /// See <doc:StreamingAndOwnership> for the full async contract.
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
        body: @escaping @Sendable (borrowing ZIPReader) throws -> T,
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
