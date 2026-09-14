#!/usr/bin/env wift

import Darwin
import Wift

let options: [String]
switch Script.arguments {
case []:
    options = ["-i"]
case ["--check"]:
    options = ["--dry-run", "--Werror"]
default:
    die("Usage: format-c.swift [--check]", status: 2)
}

/// Explicit owned-code paths: never descend into vendor/.
let sources = [
    "Sources/CMinizip/MagicZipAdapter.c",
    "Sources/CMinizip/include/CMinizip.h",
    "Tests/CMinizipTestSupport/FinalizationProbe.c",
    "Tests/CMinizipTestSupport/include/FinalizationProbe.h",
    "Benchmarks/Support/jemalloc/jemalloc.h",
]

do {
    try cmd("clang-format", arguments: options + sources)
        .inDirectory(Script.directory.deletingLastPathComponent())
        .run()
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
