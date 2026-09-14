#!/usr/bin/env wift

import Darwin
import Foundation
import Wift

let root = Script.directory.deletingLastPathComponent()
let buildRoot = URL(fileURLWithPath: Script.environment["MAGICZIP_BUILD_ROOT"] ?? "/tmp/MagicZipAppleValidation", relativeTo: root)

do {
    for platform in ["macOS", "iOS", "iOS Simulator"] {
        let destination = buildRoot.appendingPathComponent(platform.replacingOccurrences(of: " ", with: "-"))
        try cmd(
            "xcodebuild",
            "-quiet",
            "-scheme",
            "MagicZip",
            "-configuration",
            "Release",
            "-destination",
            "generic/platform=\(platform)",
            "-derivedDataPath",
            destination.path,
            "CODE_SIGNING_ALLOWED=NO",
            "build",
        ).inDirectory(root).run()
    }
    try cmd(
        "xcodebuild",
        "-quiet",
        "-scheme",
        "MagicZip",
        "-destination",
        "generic/platform=macOS",
        "-derivedDataPath",
        buildRoot.appendingPathComponent("Documentation").path,
        "CODE_SIGNING_ALLOWED=NO",
        "OTHER_DOCC_FLAGS=--warnings-as-errors",
        "docbuild",
    ).inDirectory(root).run()
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
