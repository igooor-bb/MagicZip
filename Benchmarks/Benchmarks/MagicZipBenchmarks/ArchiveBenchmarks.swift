import Benchmark
import Foundation
import MagicZip

enum ArchiveBenchmarks {
    static let archiveBytes = BenchmarkMetric.custom("archive-bytes", useScalingFactor: false)
    static let archiveRatio = BenchmarkMetric.custom("archive-ratio-ppm", useScalingFactor: false)

    static var configuration: Benchmark.Configuration {
        var configuration = Benchmark.defaultConfiguration
        configuration.metrics.append(OperationMeasurement.payloadRate)
        return configuration
    }

    static func register() {
        for workload in ArchiveFixture.Workload.allCases {
            for variant in ArchiveVariant.allCases {
                registerWrite(workload, variant)
                registerExtract(workload, variant, selection: .all, suffix: "all")
                if workload == .tree {
                    registerExtract(workload, variant, selection: .paths(["tree/d00/f000.bin"]), suffix: "path")
                    registerExtract(workload, variant, selection: .subtree("tree/d00"), suffix: "subtree")
                } else {
                    registerRead(workload, variant)
                }
            }
        }
    }

    static func registerWrite(_ workload: ArchiveFixture.Workload, _ variant: ArchiveVariant) {
        let fixture = ArchiveFixture(workload, variant)
        var configuration = Self.configuration
        configuration.metrics += [archiveBytes, archiveRatio]
        Benchmark("write-\(workload.rawValue)-\(variant.rawValue)", configuration: configuration) { benchmark in
            try fixture.removeOutput()
            try OperationMeasurement.measure(benchmark, payloadBytes: fixture.inputBytes) {
                try fixture.write(to: fixture.output)
            }
            let size = try fixture.output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard let size else {
                throw FixtureError.mismatch("missing archive size")
            }
            benchmark.measurement(archiveBytes, size)
            benchmark.measurement(archiveRatio, Int(Int64(size) * 1_000_000 / Int64(fixture.inputBytes)))
            try fixture.verifyArchive(at: fixture.output)
        } setup: {
            try fixture.prepare(needsArchive: false)
        } teardown: {
            try fixture.cleanup()
        }
    }

    static func registerRead(_ workload: ArchiveFixture.Workload, _ variant: ArchiveVariant) {
        let fixture = ArchiveFixture(workload, variant)
        Benchmark("read-\(workload.rawValue)-\(variant.rawValue)", configuration: configuration) { benchmark in
            var bytes = 0
            try OperationMeasurement.measure(benchmark, payloadBytes: fixture.inputBytes) {
                try ZIPReader.withArchive(at: fixture.archive) { reader in
                    try reader.read(path: "payload.bin", password: variant.password) { chunk in
                        bytes += chunk.count
                        blackHole(chunk)
                    }
                }
            }
            // Setup checked every byte; the measured reader also checks CRC/HMAC on every iteration.
            try require(bytes == fixture.inputBytes, "streamed byte count")
        } setup: {
            try fixture.prepare(needsArchive: true)
        } teardown: {
            try fixture.cleanup()
        }
    }

    static func registerExtract(
        _ workload: ArchiveFixture.Workload,
        _ variant: ArchiveVariant,
        selection: ZIPSelection,
        suffix: String,
    ) {
        let fixture = ArchiveFixture(workload, variant)
        Benchmark("extract-\(suffix)-\(workload.rawValue)-\(variant.rawValue)", configuration: configuration) { benchmark in
            try fixture.removeOutput()
            let payloadBytes: Int = switch selection {
            case .all:
                fixture.inputBytes
            case .paths:
                1024
            case .subtree:
                100 * 1024
            }
            try OperationMeasurement.measure(benchmark, payloadBytes: payloadBytes) {
                try ZIPReader.withArchive(at: fixture.archive) { reader in
                    try reader.extract(to: fixture.output, selection: selection, password: variant.password)
                }
            }
            let selected = fixture.files.filter { path, _ in
                switch selection {
                case .all:
                    true
                case let .paths(paths):
                    paths.contains(path)
                case let .subtree(prefix):
                    path.hasPrefix(prefix + "/")
                }
            }
            try fixture.verifyExtraction(files: selected)
        } setup: {
            try fixture.prepare(needsArchive: true)
        } teardown: {
            try fixture.cleanup()
        }
    }
}
