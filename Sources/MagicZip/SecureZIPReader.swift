import Foundation

/// Opens minizip-ng CDCD archives only after decrypting and authenticating their catalog.
/// Requires a password at scope entry. Catalog memory is capped at 64 MiB, in addition to
/// ZIPLimits for entries, paths and file payloads. Not compatible with PKWARE encrypted catalogs.
/// This scoped session is not Sendable. Concurrent/reentrant operations fail; escaped sessions
/// cannot read after close. Owned metadata snapshots remain available after the scope ends.
public final class SecureZIPReader {
    private let core: ZIPReader
    private let password: String

    private init(core: ZIPReader, password: String) {
        self.core = core
        self.password = password
    }

    /// Owned catalog snapshots, available only after catalog authentication has succeeded.
    public var entries: [ZIPEntry] {
        core.entries
    }

    /// Authenticates the catalog before invoking the body; always checks archive closure.
    /// File payload integrity is checked when each file is read, not while listing.
    public static func withArchive<T>(
        at url: URL,
        password: String,
        limits: ZIPLimits = ZIPLimits(),
        body: (SecureZIPReader) throws -> T,
    ) throws -> T {
        try withArchive(at: url, password: password, limits: limits, cancellation: nil, body: body)
    }

    static func withArchive<T>(
        at url: URL,
        password: String,
        limits: ZIPLimits,
        cancellation: ArchiveCancellation?,
        body: (SecureZIPReader) throws -> T,
    ) throws -> T {
        try withPassword(password) { _ in }
        return try ZIPReader.withArchive(at: url, limits: limits, cancellation: cancellation, securePassword: password) { core in
            try body(SecureZIPReader(core: core, password: password))
        }
    }

    /// Runs a synchronous scope on the bounded archive queue; cancellation waits for cleanup.
    public static func withArchiveAsync<T: Sendable>(
        at url: URL,
        password: String,
        limits: ZIPLimits = ZIPLimits(),
        body: @escaping @Sendable (SecureZIPReader) throws -> T,
    ) async throws -> T {
        try await ArchiveExecutor.shared.run { cancellation in
            try withArchive(at: url, password: password, limits: limits, cancellation: cancellation, body: body)
        }
    }

    /// Looks up an exact UTF-8 path without reading its payload.
    public func entry(at path: String) -> ZIPEntry? {
        core.entry(at: path)
    }

    /// Streams owned chunks. Treat delivered bytes as provisional until final integrity verification.
    public func read(path: String, chunkSize: Int = 64 * 1024, consumer: (Data) throws -> Void) throws {
        try core.read(path: path, password: password, chunkSize: chunkSize, consumer: consumer)
    }

    /// Returns verified bytes, bounded by maximumBytes as well as ZIPLimits.
    public func data(path: String, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
        try core.data(path: path, password: password, maximumBytes: maximumBytes)
    }

    /// Extracts selected files atomically with the scope password; failures preserve the old destination.
    public func extract(to destination: URL, selection: ZIPSelection = .all, overwrite: ZIPOverwrite = .fail) throws {
        try core.extract(to: destination, selection: selection, password: password, overwrite: overwrite)
    }
}
