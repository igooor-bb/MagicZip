import Darwin
import Foundation
import MagicZip
import SSZipArchive

private enum PodClientValidation {
    static let payload = Data("CocoaPods client".utf8)
    static let password = "client-password"

    static func run() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("client.zip")
        try ZIPWriter.withArchive(at: archive) { writer in
            try writer.add(data: payload, path: "hello", password: password)
        }
        try verifyMagicZip(archive)
        try verifyReferenceReader(archive, root: root)
        print("PASS: real CocoaPods client imports MagicZip; ZIP compatibility verified")
    }

    static func verifyMagicZip(_ archive: URL) throws {
        try ZIPReader.withArchive(at: archive) { reader in
            let actual = try reader.data(path: "hello", password: password)
            guard actual == payload else { throw ValidationFailure.payloadMismatch }
        }
    }

    static func verifyReferenceReader(_ archive: URL, root: URL) throws {
        let output = root.appendingPathComponent("unzip")
        try SSZipArchive.unzipFile(atPath: archive.path, toDestination: output.path, overwrite: true, password: password)
        let actual = try Data(contentsOf: output.appendingPathComponent("hello"))
        guard actual == payload else { throw ValidationFailure.payloadMismatch }
    }

    static func makeTemporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ValidationFailure.temporaryDirectory }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("MagicZipPod-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    enum ValidationFailure: Error {
        case temporaryDirectory
        case payloadMismatch
    }
}

try PodClientValidation.run()
