import Foundation

/// The ZIP engine operation associated with a failure.
///
/// Switch over cases to handle specific operations. Raw strings are intended for diagnostics,
/// not localized user-facing messages.
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

/// Details about a status reported by the ZIP engine.
///
/// Use ``code`` to identify recognized statuses and ``message`` for readable diagnostics.
/// ``rawValue`` preserves the original number, including unrecognized statuses.
/// Map recognized codes to your own localized messages when needed.
public struct ZIPBackendStatus: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    /// The original numeric status reported by the backend.
    public let rawValue: Int32

    /// Creates diagnostics for a backend status, including an unrecognized value.
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// The recognized status, or `nil` if the value is unknown.
    public var code: Code? {
        Code(rawValue: rawValue)
    }

    /// The backend's symbolic name for this status.
    ///
    /// Returns `nil` when the status is unrecognized.
    public var symbol: String? {
        code?.details.symbol
    }

    /// An English explanation of the status.
    public var message: String {
        code?.details.message ?? "Unknown minizip status."
    }

    /// A diagnostic description with the message and original status code.
    public var description: String {
        "\(message) (\(symbol ?? "minizip"), code \(rawValue))"
    }

    /// Statuses recognized by MagicZip.
    ///
    /// Includes successful completion and end-of-data statuses as well as errors.
    /// Values correspond to the backend's [status definitions](https://github.com/zlib-ng/minizip-ng/blob/4.2.2/mz.h).
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
        /// File verification failed because of a checksum or AES authentication mismatch.
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
    /// Diagnostic details for a backend failure.
    ///
    /// Returns `nil` for other error cases. For ``ZIPError/combined(primary:cleanup:)``, inspect
    /// both errors separately to retain the full context.
    var backendStatus: ZIPBackendStatus? {
        guard case let .backend(_, _, status) = self else {
            return nil
        }
        return ZIPBackendStatus(rawValue: status)
    }
}

extension ZIPError: LocalizedError {
    /// An English description of the error for logs or a fallback message.
    ///
    /// Combined failures include both descriptions. Use error cases to provide localized UI.
    public var errorDescription: String? {
        switch self {
        case let .backend(operation, path, status):
            "Failed to \(operation.rawValue)\(path.map { " [\($0)]" } ?? ""): \(ZIPBackendStatus(rawValue: status))"

        case let .fileSystem(operation, path, code):
            "Failed to \(operation.rawValue) [\(path)]: " +
                "\(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription) (POSIX \(code))"

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
