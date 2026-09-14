#!/usr/bin/env wift

import Darwin
import Foundation
import Wift

let root = Script.directory.deletingLastPathComponent()
let environment = Script.environment
let arguments = Script.arguments

if environment["BENCHMARK_DISABLE_JEMALLOC"] != nil || environment["BENCHMARK_DISABLE_MALLOC_INTERPOSER"] != nil {
    die("Benchmark allocation metrics require the allocator backend; unset BENCHMARK_DISABLE_* variables.")
}

do {
    let jemallocPrefix = try cmd("mise", "where", "conda:jemalloc").inDirectory(root).text()
    for file in ["include/jemalloc/jemalloc.h", "lib/libjemalloc.dylib"] {
        guard FileManager.default.fileExists(atPath: "\(jemallocPrefix)/\(file)") else {
            die("Missing jemalloc: run mise install conda:jemalloc@5.3.0.")
        }
    }

    // Nested plugin builds read pkg-config; command-line -Xcc flags alone are insufficient.
    let pkgConfigDirectory = root.appendingPathComponent("Benchmarks/.build/jemalloc-pkgconfig")
    try FileManager.default.createDirectory(at: pkgConfigDirectory, withIntermediateDirectories: true)
    let pkgConfig = """
    Name: jemalloc
    Description: mise conda jemalloc with Benchmark statistics names
    Version: 5.3.0
    Cflags: -I"\(root.path)/Benchmarks/Support" -I"\(jemallocPrefix)/include"
    Libs: -L"\(jemallocPrefix)/lib" -ljemalloc

    """
    try pkgConfig.write(to: pkgConfigDirectory.appendingPathComponent("jemalloc.pc"), atomically: true, encoding: .utf8)
    var pkgConfigPaths = [pkgConfigDirectory.path]
    if let inherited = environment["PKG_CONFIG_PATH"], !inherited.isEmpty {
        pkgConfigPaths.append(inherited)
    }

    // Conda's dylib uses @rpath; no global DYLD variables are needed.
    let packageArguments = [
        "package",
        "--package-path",
        "Benchmarks",
        "-c",
        "release",
        "-Xlinker",
        "-rpath",
        "-Xlinker",
        "\(jemallocPrefix)/lib",
        "--allow-writing-to-package-directory",
        "benchmark",
    ]
    try cmd("swift", arguments: packageArguments + arguments)
        .inDirectory(root)
        .environment(["PKG_CONFIG_PATH": pkgConfigPaths.joined(separator: ":")])
        .run()

    if arguments.starts(with: ["baseline", "update"]) {
        let baseline = arguments.dropFirst(2).first ?? ""
        try cmd("python3", "Scripts/benchmark-metadata.py", baseline, jemallocPrefix).inDirectory(root).run()
    }
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
