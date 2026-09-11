import Darwin
import Foundation
import MagicZip
import ZipArchive

private enum ZIPCompatibilityValidation {
    static let payload = Data("SSZipArchive and MagicZip coexist — Привет!".utf8)

    static func run() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try payload.write(to: source)

        for password: String? in [nil, "interop-password"] {
            try readReferenceArchive(source: source, root: root, password: password)
            try readMagicZip(root: root, password: password)
        }
        print("PASS: independent ZIP compatibility, plaintext and AES-256, isolated C symbols")
    }

    static func readReferenceArchive(source: URL, root: URL, password: String?) throws {
        let name = password == nil ? "sszip-plain.zip" : "sszip-aes.zip"
        let archive = root.appendingPathComponent(name)
        guard SSZipArchive.createZipFile(atPath: archive.path, withFilesAtPaths: [source.path], withPassword: password) else {
            throw ValidationFailure.archiveCreation
        }
        try ZIPReader.withArchive(at: archive) { reader in
            let actual = try reader.data(path: "source.txt", password: password)
            guard actual == payload else { throw ValidationFailure.payloadMismatch }
        }
        try saveFixtureIfRequested(archive)
    }

    static func readMagicZip(root: URL, password: String?) throws {
        let archive = root.appendingPathComponent("own.zip")
        try ZIPWriter.withArchive(at: archive, overwrite: .replace) {
            try $0.add(data: payload, path: "source.txt", password: password)
        }
        let output = root.appendingPathComponent(password == nil ? "ss-out-plain" : "ss-out-aes")
        try SSZipArchive.unzipFile(atPath: archive.path, toDestination: output.path, overwrite: true, password: password)
        let actual = try Data(contentsOf: output.appendingPathComponent("source.txt"))
        guard actual == payload else { throw ValidationFailure.payloadMismatch }
    }

    static func saveFixtureIfRequested(_ archive: URL) throws {
        guard CommandLine.arguments.count == 2 else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let destination = directory.appendingPathComponent(archive.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: archive, to: destination)
    }

    static func makeTemporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ValidationFailure.temporaryDirectory }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("MagicZipInterop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    enum ValidationFailure: Error {
        case temporaryDirectory
        case archiveCreation
        case payloadMismatch
    }
}

try ZIPCompatibilityValidation.run()
