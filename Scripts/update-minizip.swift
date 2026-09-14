#!/usr/bin/env wift

import Darwin
import Wift

do {
    try cmd("python3", arguments: ["Scripts/minizip/import.py"] + Script.arguments)
        .inDirectory(Script.directory.deletingLastPathComponent())
        .run()
} catch let CommandError.unsuccessful(_, result) {
    exit(result.termination.exitCode)
} catch {
    die("\(error)")
}
