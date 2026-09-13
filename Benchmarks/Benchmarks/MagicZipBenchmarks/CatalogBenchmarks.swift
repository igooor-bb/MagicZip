import Benchmark
import Foundation
import MagicZip

enum CatalogBenchmarks {
    static func register() {
        for count in [1000, 10000] {
            let fixture = ArchiveFixture(.tree, .store)
            Benchmark("catalog-\(count)-store") { benchmark in
                let entries = try OperationMeasurement.measure(benchmark) {
                    try ZIPReader.withArchive(at: fixture.archive) { reader in
                        blackHole(reader.entries)
                        return reader.entries
                    }
                }
                try require(entries.count == count, "catalog count")
                for (index, entry) in entries.enumerated() {
                    try require(entry.path == "file-\(index).bin" && entry.uncompressedSize == 0, "catalog entry")
                }
            } setup: {
                try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
                do {
                    try ZIPWriter.withArchive(at: fixture.archive) { writer in
                        for index in 0 ..< count {
                            try writer.add(
                                data: Data(),
                                path: "file-\(index).bin",
                                compression: .store,
                                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                            )
                        }
                    }
                } catch {
                    try fixture.cleanup()
                    throw error
                }
            } teardown: {
                try fixture.cleanup()
            }
        }
    }
}
