#!/usr/bin/env wift

import Darwin
import Foundation
import Wift

let root = Script.directory.deletingLastPathComponent()
let buildRoot = URL(fileURLWithPath: Script.environment["MAGICZIP_POD_BUILD_ROOT"] ?? "/tmp/MagicZipPodValidation", relativeTo: root)

do {
    try cmd("bundle", "exec", "ruby", "Validation/PodClient/generate.rb").inDirectory(root).run()
    try cmd("bundle", "exec", "pod", "install", "--project-directory=Validation/PodClient").inDirectory(root).run()
    for platform in ["macOS", "iOS", "iOS Simulator"] {
        let scheme = platform == "macOS" ? "ClientMac" : "ClientIOS"
        let destination = buildRoot.appendingPathComponent(platform.replacingOccurrences(of: " ", with: "-"))
        try cmd(
            "xcodebuild",
            "-quiet",
            "-workspace",
            "Validation/PodClient/Client.xcworkspace",
            "-scheme",
            scheme,
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
    try cmd(buildRoot.appendingPathComponent("macOS/Build/Products/Release/ClientMac.app/Contents/MacOS/ClientMac").path)
        .inDirectory(root).run()
    // Unpublished source/homepage URLs and upstream SDK warnings are allowed; compilation errors are not.
    try cmd(
        "bundle",
        "exec",
        "pod",
        "lib",
        "lint",
        "MagicZip.podspec",
        "--include-podspecs=MagicZipCMinizip.podspec",
        "--platforms=ios,osx",
        "--skip-tests",
        "--use-libraries",
        "--allow-warnings",
    ).inDirectory(root).run()
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
