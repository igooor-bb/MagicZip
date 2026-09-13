// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MagicZipBenchmarks",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/benchmark", exact: "1.36.0"),
    ],
    targets: [
        .executableTarget(
            name: "MagicZipBenchmarks",
            dependencies: [
                .product(name: "MagicZip", package: "MagicZip"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/MagicZipBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")],
        ),
    ],
)
