import Foundation
import Testing
@testable import MagicZip

struct BackendErrorTests {
    @Test func `status mapping preserves backend symbols and unknown codes`() throws {
        let samples: [(Int32, ZIPBackendStatus.Code, String)] = [
            (-103, .formatError, "MZ_FORMAT_ERROR"),
            (-105, .integrityError, "MZ_CRC_ERROR"),
            (-108, .passwordError, "MZ_PASSWORD_ERROR"),
            (-116, .writeError, "MZ_WRITE_ERROR"),
        ]
        for (raw, code, symbol) in samples {
            let status = ZIPBackendStatus(rawValue: raw)
            #expect(status.rawValue == raw)
            #expect(status.code == code)
            #expect(status.symbol == symbol)
            #expect(status.description.contains(String(raw)))
        }
        #expect(ZIPBackendStatus(rawValue: -105).message.contains("AES authentication"))
        try check(0, .readEntry)
        do {
            try check(-32000, .readEntry, path: "file.txt")
            Issue.record("Unknown nonzero code was accepted")
        } catch let error as ZIPError {
            guard case let .backend(operation, path, raw) = error else {
                Issue.record("Backend context was lost")
                return
            }
            #expect(operation == .readEntry)
            #expect(path == "file.txt")
            #expect(raw == -32000)
            #expect(error.backendStatus?.code == nil)
            #expect(error.localizedDescription.contains("-32000"))
            #expect(error.localizedDescription.contains("Unknown minizip status"))
        }
    }

    @Test func `real password failures have typed stage and original code`() throws {
        try ZIPReader.withArchive(at: fixture("aes2.zip")) { reader in
            for password: String? in [nil, "definitely-wrong-password"] {
                do {
                    _ = try reader.data(path: "secret.txt", password: password)
                    Issue.record("Missing or wrong password was accepted")
                } catch let error as ZIPError {
                    guard case let .backend(operation, path, raw) = error else {
                        Issue.record("Backend context was lost")
                        return
                    }
                    #expect(operation == (password == nil ? .openEncryptedEntry : .openEntry))
                    #expect(path == "secret.txt")
                    #expect(raw == -108)
                    #expect(error.backendStatus?.code == .passwordError)
                    #expect(error.localizedDescription.contains("MZ_PASSWORD_ERROR"))
                    #expect(!error.localizedDescription.contains("definitely-wrong-password"))
                }
            }
        }
    }

    @Test func `AES authentication failure is not misreported as only CRC`() throws {
        do {
            try SecureZIPReader.withArchive(at: fixture("secure-catalog-corrupt.zip"), password: "fixture-password") { _ in
                Issue.record("Corrupt catalog was accepted")
            }
        } catch let error as ZIPError {
            guard case let .backend(operation, _, raw) = error else {
                Issue.record("Backend context was lost")
                return
            }
            #expect(operation == .authenticateAndCloseCatalog)
            #expect(raw == -105)
            #expect(error.backendStatus?.code == .integrityError)
            #expect(error.localizedDescription.contains("AES authentication"))
        }
    }

    @Test func `combined errors preserve both diagnostic branches`() {
        let primary = ZIPError.backend(operation: .readEntry, path: "file", status: -115)
        let cleanup = ZIPError.backend(operation: .closeArchive, path: nil, status: -112)
        let error = ZIPError.combined(primary: primary, cleanup: cleanup)
        #expect(error.backendStatus == nil)
        #expect(error.localizedDescription.contains("MZ_READ_ERROR"))
        #expect(error.localizedDescription.contains("MZ_CLOSE_ERROR"))
        #expect(error.localizedDescription.contains("-115"))
        #expect(error.localizedDescription.contains("-112"))
    }
}
