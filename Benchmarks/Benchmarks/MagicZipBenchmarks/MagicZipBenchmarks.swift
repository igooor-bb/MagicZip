import Benchmark

let benchmarks: @Sendable () -> Void = {
    var metrics: [BenchmarkMetric] = [
        .wallClock,
        .cpuTotal,
        .throughput,
        .peakMemoryResident,
        .peakMemoryResidentDelta,
        .mallocCountTotal,
        OperationMeasurement.operationRate,
    ]
    #if compiler(>=6.3)
        metrics.append(.mallocBytesCount)
    #else
        // Benchmark 1.36's jemalloc backend does not produce mallocBytesCount.
        metrics.append(.allocatedResidentMemory)
    #endif
    Benchmark.defaultConfiguration = .init(
        metrics: metrics,
        warmupIterations: 3,
        maxDuration: .seconds(5),
        maxIterations: 100,
    )
    ArchiveBenchmarks.register()
    CatalogBenchmarks.register()
}

enum OperationMeasurement {
    static let operationRate = BenchmarkMetric.custom("throughput-microops-per-second", polarity: .prefersLarger, useScalingFactor: false)
    static let payloadRate = BenchmarkMetric.custom("payload-bytes-per-second", polarity: .prefersLarger, useScalingFactor: false)

    static func measure<T>(_ benchmark: Benchmark, payloadBytes: Int? = nil, body: () throws -> T) throws -> T {
        benchmark.startMeasurement()
        let start = ContinuousClock.now
        let result = try body()
        let duration = start.duration(to: .now).components
        benchmark.stopMeasurement()
        let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        try require(seconds > 0, "nonpositive operation duration")
        benchmark.measurement(operationRate, Int((1_000_000 / seconds).rounded()))
        if let payloadBytes {
            benchmark.measurement(payloadRate, Int((Double(payloadBytes) / seconds).rounded()))
        }
        return result
    }
}
