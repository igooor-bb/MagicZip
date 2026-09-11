import Darwin
import Foundation
import MagicZip

private enum StreamingValidation {
    static let checksZIP64 = CommandLine.arguments.contains("--zip64")
    static let payloadBytes: Int64 = checksZIP64 ? 5 * 1024 * 1024 * 1024 : 512 * 1024 * 1024
    static let limits = ZIPLimits(maximumEntryBytes: payloadBytes, maximumTotalBytes: payloadBytes)
    static let maximumResidentMiB: Double = 128

    static func run() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("large.zip")

        try writeLargeArchive(at: archive)
        try verifyStreamingRead(at: archive)
        try corruptLargeEntry(in: archive)
        try verifySelectiveExtraction(archive: archive, root: root)
        let peak = try peakResidentMiB()
        guard peak < maximumResidentMiB else { throw ValidationFailure.memoryBudgetExceeded(peak) }
        print("PASS: streamed \(payloadBytes) bytes; peak RSS \(String(format: "%.1f", peak)) MiB; corrupt unselected payload untouched")
    }

    static func writeLargeArchive(at archive: URL) throws {
        let chunk = Data((0 ..< 65536).map { UInt8(truncatingIfNeeded: $0) })
        try ZIPWriter.withArchive(at: archive) { writer in
            var remaining = payloadBytes
            try writer.addStream(path: "large.bin", compression: checksZIP64 ? .deflate() : .store) { _ in
                guard remaining > 0 else { return nil }
                remaining -= Int64(chunk.count)
                return chunk
            }
            try writer.add(data: Data("selected".utf8), path: "wanted.txt")
        }
    }

    static func verifyStreamingRead(at archive: URL) throws {
        var bytesRead: Int64 = 0
        try ZIPReader.withArchive(at: archive, limits: limits) { reader in
            try reader.read(path: "large.bin") { bytesRead += Int64($0.count) }
        }
        guard bytesRead == payloadBytes else { throw ValidationFailure.payloadMismatch }
    }

    static func corruptLargeEntry(in archive: URL) throws {
        // Offset 1024 lies inside the first entry payload, after its local ZIP64 header.
        // Successful selective extraction afterward proves this payload was not verified/decompressed.
        let file = try FileHandle(forUpdating: archive)
        do {
            try file.seek(toOffset: 1024)
            try file.write(contentsOf: Data([0xFF]))
        } catch {
            try? file.close()
            throw error
        }
        try file.close()
    }

    static func verifySelectiveExtraction(archive: URL, root: URL) throws {
        let output = root.appendingPathComponent("selected")
        try ZIPReader.withArchive(at: archive, limits: limits) { reader in
            try reader.extract(to: output, selection: .paths(["wanted.txt"]))
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: output.path)
        let data = try Data(contentsOf: output.appendingPathComponent("wanted.txt"))
        guard contents == ["wanted.txt"], data == Data("selected".utf8) else { throw ValidationFailure.payloadMismatch }
    }

    static func peakResidentMiB() throws -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ValidationFailure.resourceUsage }
        return Double(usage.ru_maxrss) / 1024 / 1024
    }

    static func makeTemporaryDirectory() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ValidationFailure.temporaryDirectory }
        defer { free(path) }
        let root = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("MagicZipMemory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    enum ValidationFailure: Error {
        case temporaryDirectory
        case payloadMismatch
        case resourceUsage
        case memoryBudgetExceeded(Double)
    }
}

try StreamingValidation.run()
