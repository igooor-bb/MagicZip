import Foundation

/// The backend stage that failed. Switch over cases rather than parsing diagnostic strings.
/// Raw values describe stages for diagnostics; they are not localized UI copy.
public enum ZIPBackendOperation: String, Sendable, CaseIterable {
    case openArchive = "open archive"
    case closeArchive = "close archive"
    case inspectCatalog = "inspect catalog"
    case inspectEncryptedCatalog = "inspect encrypted catalog"
    case readCatalogMetadata = "read catalog metadata"
    case validateCatalogSize = "validate catalog size"
    case openEncryptedCatalog = "open encrypted catalog"
    case readEncryptedCatalog = "read encrypted catalog"
    case bufferEncryptedCatalog = "buffer encrypted catalog"
    case authenticateAndCloseCatalog = "authenticate/close catalog"
    case installAuthenticatedCatalog = "install authenticated catalog"
    case openOutputCatalog = "open output catalog"
    case writeOutputCatalog = "write output catalog"
    case finalizeOutputCatalog = "finalize output catalog"
    case closeOutputCatalog = "close output catalog"
    case openEncryptedEntry = "open encrypted entry"
    case seekEntry = "seek entry"
    case openEntry = "open entry"
    case readEntry = "read entry"
    case verifyAndCloseEntry = "verify/close entry"
    case countEntries = "count entries"
    case enumerateEntries = "enumerate entries"
    case readMetadata = "read metadata"
    case validateSizes = "validate sizes"
    case validateEntryCount = "validate entry count"
    case openOutputEntry = "open output entry"
    case writeEntry = "write entry"
    case shortWrite = "short write"
    case finalizeEntry = "finalize entry"
}

/// A lossless interpretation of a minizip status, including future or unknown values.
/// `rawValue` always preserves the original code; `code` is nil when it is unrecognized.
/// Messages are English diagnostic text. Use code cases for application-specific localization.
public struct ZIPBackendStatus: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public var code: Code? {
        Code(rawValue: rawValue)
    }

    /// Original minizip symbol, or nil for an unrecognized status.
    public var symbol: String? {
        code?.details.symbol
    }

    /// Human-readable meaning without discarding or guessing the underlying status.
    public var message: String {
        code?.details.message ?? "Unknown minizip status."
    }

    /// Meaning, backend symbol (when known), and the original numeric code.
    public var description: String {
        "\(message) (\(symbol ?? "minizip"), code \(rawValue))"
    }

    /// Status definitions from the pinned backend; success/end sentinels are included for completeness.
    /// https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz.h
    public enum Code: Int32, Sendable, CaseIterable {
        case success = 0
        case streamError = -1
        case dataError = -3
        case memoryError = -4
        case bufferError = -5
        case versionError = -6
        case endOfList = -100
        case endOfStream = -101
        case parameterError = -102
        case formatError = -103
        case internalError = -104
        // minizip's AES stream also returns MZ_CRC_ERROR for an HMAC mismatch.
        // https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz_strm_wzaes.c
        case integrityError = -105
        case cryptographicError = -106
        case notFound = -107
        case passwordError = -108
        case unsupported = -109
        case hashError = -110
        case openError = -111
        case closeError = -112
        case seekError = -113
        case tellError = -114
        case readError = -115
        case writeError = -116
        case signatureError = -117
        case symlinkError = -118

        fileprivate var details: (symbol: String, message: String) {
            switch self {
            case .success:
                ("MZ_OK", "Operation completed successfully.")
            case .streamError:
                ("MZ_STREAM_ERROR", "Stream operation failed or the codec stream state is invalid.")
            case .dataError:
                ("MZ_DATA_ERROR", "Archive data is invalid, corrupted, or has an unexpected size.")
            case .memoryError:
                ("MZ_MEM_ERROR", "The backend could not allocate memory.")
            case .bufferError:
                ("MZ_BUF_ERROR", "A buffer limit was reached or the codec could not make progress.")
            case .versionError:
                ("MZ_VERSION_ERROR", "The codec version is incompatible.")
            case .endOfList:
                ("MZ_END_OF_LIST", "End of archive entry list.")
            case .endOfStream:
                ("MZ_END_OF_STREAM", "End of data stream.")
            case .parameterError:
                ("MZ_PARAM_ERROR", "A backend parameter or operation state is invalid.")
            case .formatError:
                ("MZ_FORMAT_ERROR", "The ZIP structure or metadata is invalid.")
            case .internalError:
                ("MZ_INTERNAL_ERROR", "An internal backend operation failed.")
            case .integrityError:
                ("MZ_CRC_ERROR", "Integrity verification failed (CRC or AES authentication).")
            case .cryptographicError:
                ("MZ_CRYPT_ERROR", "A cryptographic operation failed.")
            case .notFound:
                ("MZ_EXIST_ERROR", "The requested item or backend property was not found.")
            case .passwordError:
                ("MZ_PASSWORD_ERROR", "A password is missing or does not match.")
            case .unsupported:
                ("MZ_SUPPORT_ERROR", "The backend does not support this archive feature or operation.")
            case .hashError:
                ("MZ_HASH_ERROR", "A hash operation or verification failed.")
            case .openError:
                ("MZ_OPEN_ERROR", "The backend could not open a stream.")
            case .closeError:
                ("MZ_CLOSE_ERROR", "The backend could not close or finalize a stream.")
            case .seekError:
                ("MZ_SEEK_ERROR", "The backend could not seek to the requested position.")
            case .tellError:
                ("MZ_TELL_ERROR", "The backend could not determine the stream position.")
            case .readError:
                ("MZ_READ_ERROR", "The backend could not read the requested data.")
            case .writeError:
                ("MZ_WRITE_ERROR", "The backend could not write all requested data.")
            case .signatureError:
                ("MZ_SIGN_ERROR", "A digital signature operation or verification failed.")
            case .symlinkError:
                ("MZ_SYMLINK_ERROR", "The backend rejected or could not process a symbolic link.")
            }
        }
    }
}

public extension ZIPError {
    /// Backend diagnostics for this error. Combined errors keep each branch separately;
    /// inspect their primary and cleanup values rather than losing one to a single status.
    var backendStatus: ZIPBackendStatus? {
        guard case let .backend(_, _, status) = self else {
            return nil
        }
        return ZIPBackendStatus(rawValue: status)
    }
}

extension ZIPError: LocalizedError {
    /// English diagnostic context suitable for logging or a fallback error display.
    /// Callback errors remain unchanged; combined failures retain both descriptions.
    public var errorDescription: String? {
        switch self {
        case let .backend(operation, path, status):
            "Failed to \(operation.rawValue)\(path.map { " [\($0)]" } ?? ""): \(ZIPBackendStatus(rawValue: status))"
        case let .fileSystem(operation, path, code):
            "Failed to \(operation) [\(path)]: \(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription) (POSIX \(code))"
        case .closed:
            "The archive session is closed or was invalidated by an earlier failure."
        case .busy:
            "The archive session is already performing an operation."
        case let .invalidArgument(reason):
            "Invalid archive option: \(reason)"
        case let .unsafePath(path):
            "Unsafe archive path: \(path)"
        case let .conflictingPath(path):
            "Conflicting archive path: \(path)"
        case let .unsupported(path, feature):
            "Unsupported archive feature\(path.map { " [\($0)]" } ?? ""): \(feature)"
        case let .limitExceeded(context):
            "Archive resource limit exceeded: \(context)"
        case let .entryNotFound(path):
            "Archive entry not found: \(path)"
        case let .combined(primary, cleanup):
            "\(primary.localizedDescription) Cleanup also failed: \(cleanup.localizedDescription)"
        }
    }
}
