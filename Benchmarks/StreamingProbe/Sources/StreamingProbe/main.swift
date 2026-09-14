import Darwin
import Foundation
import MagicZip

/// Private, process-per-measurement probe. Dataset preparation and compilation are not timed.
enum PerformanceProbe {
    static func run(_ arguments: [String]) throws {
        let root = URL(fileURLWithPath: arguments[1])
        let operation = arguments[2]
        let variant = arguments[3]
        let password = variant.contains("aes") ? "benchmark-password" : nil
        let compression: ZIPCompression = variant.contains("deflate") ? .deflate() : .store
        let archive = root.appendingPathComponent(variant + ".zip")
        let start = ContinuousClock.now
        switch operation {
        case "write":
            try ZIPWriter.withArchive(at: archive, password: password, overwrite: .replace) {
                try $0.add(file: root.appendingPathComponent("payload"), path: "payload", compression: compression)
            }

        case "tree":
            try ZIPWriter.withArchive(at: archive, password: password, overwrite: .replace) {
                try $0.add(directory: root.appendingPathComponent("small"), path: "small", compression: compression)
            }

        case "read":
            var count: Int64 = 0
            try ZIPReader.withArchive(at: archive) {
                for entry in $0.entries where !entry.isDirectory {
                    try $0.read(path: entry.path, password: password) { count += Int64($0.count) }
                }
            }
            guard count > 0 else {
                throw ProbeError.empty
            }

        case "extract":
            try ZIPReader.withArchive(at: archive) {
                try $0.extract(to: root.appendingPathComponent("extracted"), password: password, overwrite: .replace)
            }

        case "paths":
            #if BASELINE
                let limits = ZIPLimits()
            #else
                let limits = ZIPLimits(maximumPathDepth: 10000)
            #endif
            try ZIPReader.withArchive(at: root, limits: limits) { guard $0.entries.count == 1 else {
                throw ProbeError.empty
            } }

        default:
            throw ProbeError.argument
        }
        let duration = start.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw ProbeError.argument
        }
        var heap = malloc_statistics_t()
        malloc_zone_statistics(nil, &heap)
        print("\(operation),\(variant),\(seconds),\(Double(usage.ru_maxrss) / 1_048_576),\(heap.max_size_in_use),\(heap.blocks_in_use)")
    }

    enum ProbeError: Error {
        case empty, argument
    }
}

try PerformanceProbe.run(Array(CommandLine.arguments.dropFirst()))
