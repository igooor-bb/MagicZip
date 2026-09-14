#!/usr/bin/env wift

import Darwin
import Wift

enum TreeTestError: Error {
    case timedOut
}

let root = Script.directory.deletingLastPathComponent()

do {
    // Compile before the selected test process applies its own descriptor/file-size limits.
    try await cmd("swift", "build", "--build-tests").inDirectory(root).run()
    let tests = cmd("swift", "test", "--skip-build", "--filter", "TreeResourceTests")
        .inDirectory(root)
        .environment(["MAGICZIP_TREE_PROBE": "1"])

    try await withThrowingTaskGroup(of: Void.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await tests.run() }
        group.addTask {
            try await Task.sleep(for: .seconds(120))
            throw TreeTestError.timedOut
        }
        // Wift cancellation terminates and reaps the child before this scope returns.
        try await group.next()
    }
} catch TreeTestError.timedOut {
    die("Tree resource tests exceeded 120 seconds.")
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
