import CMinizip
import CMinizipTestSupport
import Foundation
import Testing
@testable import MagicZip

struct SecurityTests {
    @Test(arguments: ["aes128-ae2-store.zip", "aes192-ae2-store.zip", "aes-store2.zip"])
    func `AES framing is rejected before opening the body`(name: String) throws {
        let minimum = name.hasPrefix("aes128") ? 20 : (name.hasPrefix("aes192") ? 24 : 28)
        let original = try Data(contentsOf: fixture(name))
        let header = try #require(original.range(of: Data([0x50, 0x4B, 1, 2]))).lowerBound
        for size in [0, 1, minimum - 1] {
            try temporaryDirectory { root in
                var bytes = original
                var replacement = Data()
                replacement.appendLittleEndian(UInt32(size))
                replacement.appendLittleEndian(UInt32(0))
                bytes.replaceSubrange(header + 20 ..< header + 28, with: replacement)
                let url = root.appendingPathComponent("small-aes.zip")
                try bytes.write(to: url)
                #expect(throws: ZIPError.self) {
                    try ZIPReader.withArchive(at: url) { _ in Issue.record("Invalid framing reached body") }
                }
            }
        }
    }

    @Test(arguments: 1 ... 8)
    func `crypto failures stop encrypted output`(stage: Int32) {
        #expect(magiczip_test_crypto_failure(stage, 0) == 1)
        if stage != 1 { // Reading consumes a salt rather than generating one.
            #expect(magiczip_test_crypto_failure(stage, 1) == 1)
        }
    }

    @Test func `catalog growth is amortized and failed allocation preserves data`() {
        #expect(magiczip_test_memory_growth() == 1)
    }

    @Test(arguments: [0, 128 * 1024])
    func `decoded catalog cannot outgrow its declared capacity`(length: Int32) {
        #expect(magiczip_test_catalog_capacity(fixture("python.zip").path, length) == 1)
    }

    @Test func `Deflate input refills are bounded and interruptible without output`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("empty-blocks.zip")
            try emptyDeflateArchive(blocks: 40000).write(to: archive)
            var calls: Int32 = 0
            #expect(magiczip_test_controlled_read(archive.path, 3, &calls) == -115)
            #expect(calls == 3) // One native read was interrupted during its third refill.

            try emptyDeflateArchive(blocks: 40000, declaredSize: 10).write(to: archive)
            #expect(magiczip_test_controlled_read(archive.path, 0, &calls) < 0)
            #expect(calls <= 2) // It cannot consume the rest of the actual Deflate stream.
        }
    }

    @Test func `native cancellation preserves Swift error and clears borrowed callback`() throws {
        try temporaryDirectory { root in
            let archive = root.appendingPathComponent("empty-blocks.zip")
            try emptyDeflateArchive(blocks: 100).write(to: archive)
            var native = try NativeArchive(fileDescriptor: FileSystem.openFile(archive), writing: false)
            try completing {
                try check(magiczip_first(native.pointer), .enumerateEntries)
                try check(magiczip_read_open(native.pointer, nil), .openEntry)
                let token = ArchiveCancellation()
                token.cancel()
                var buffer = [UInt8](repeating: 0, count: 64)
                #expect(throws: CancellationError.self) {
                    try buffer.withUnsafeMutableBytes { try native.read(into: $0, cancellation: token) }
                }
                try check(magiczip_read_close(native.pointer, 0), .verifyAndCloseEntry)
                try check(magiczip_read_open(native.pointer, nil), .openEntry)
                let count = try buffer.withUnsafeMutableBytes { try native.read(into: $0, cancellation: nil) }
                #expect(count == 0)
                try check(magiczip_read_close(native.pointer, 1), .verifyAndCloseEntry)
            } cleanup: {
                try native.close()
            }
        }
    }

}

/// A complete ZIP with a raw Deflate stream made of empty stored blocks. It exercises
/// repeated codec input refills without generating uncompressed bytes or relying on timing.
private func emptyDeflateArchive(blocks: Int, declaredSize: UInt32? = nil) -> Data {
    var payload = Data()
    for _ in 0 ..< blocks {
        payload.append(contentsOf: [0, 0, 0, 255, 255])
    }
    payload.append(contentsOf: [1, 0, 0, 255, 255])
    let size = declaredSize ?? UInt32(payload.count)
    var bytes = Data()
    bytes.appendLittleEndian(UInt32(0x0403_4B50))
    for value: UInt16 in [20, 0, 8] {
        bytes.appendLittleEndian(value)
    }
    for value: UInt32 in [0x0021_0000, 0, size, 0] {
        bytes.appendLittleEndian(value)
    }
    for value: UInt16 in [1, 0] {
        bytes.appendLittleEndian(value)
    }
    bytes.append(120) // x
    bytes.append(payload)
    let offset = UInt32(bytes.count)
    bytes.appendLittleEndian(UInt32(0x0201_4B50))
    for value: UInt16 in [20, 20, 0, 8] {
        bytes.appendLittleEndian(value)
    }
    for value: UInt32 in [0x0021_0000, 0, size, 0] {
        bytes.appendLittleEndian(value)
    }
    for value: UInt16 in [1, 0, 0, 0, 0] {
        bytes.appendLittleEndian(value)
    }
    for value: UInt32 in [0, 0] {
        bytes.appendLittleEndian(value)
    }
    bytes.append(120)
    let catalogSize = UInt32(bytes.count) - offset
    bytes.appendLittleEndian(UInt32(0x0605_4B50))
    for value: UInt16 in [0, 0, 1, 1] {
        bytes.appendLittleEndian(value)
    }
    bytes.appendLittleEndian(catalogSize)
    bytes.appendLittleEndian(offset)
    bytes.appendLittleEndian(UInt16(0))
    return bytes
}

private extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
