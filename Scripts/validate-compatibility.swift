#!/usr/bin/env wift

import Darwin
import Wift

let root = Script.directory.deletingLastPathComponent()

do {
    try cmd("swift", "run", "--package-path", "Validation/Compatibility", "CompatibilityValidation").inDirectory(root).run()
    let buildDirectory = try cmd("swift", "build", "--package-path", "Validation/Compatibility", "--show-bin-path")
        .inDirectory(root).text()
    try cmd("python3", "Scripts/check-c-symbols.py", "\(buildDirectory)/CMinizip.build").inDirectory(root).run()
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
