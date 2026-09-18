import Darwin
import Foundation
import Testing
@testable import MagicZip

struct FileSystemLongPathTests {
    @Test(arguments: [false, true])
    func `existing directory beyond PATH_MAX opens without creating parents`(createIntermediates: Bool) throws {
        try withLongDirectory { url, expected in
            let direct = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            let directError = errno
            if direct >= 0 {
                close(direct)
            }
            try #require(direct == -1)
            try #require(directError == ENAMETOOLONG)

            let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
            #expect(try FileIdentity(opened) == FileIdentity(expected))
        }
    }

    @Test func `archive round trip beyond PATH_MAX creates parents through an existing alias`() throws {
        try withLongDirectory { url, directory in
            try #require(symlinkat(".", directory.raw, "alias") == 0)
            let archive = url.appendingPathComponent("alias/exports/nested/resources.zip")
            let contents = Data("long path contents".utf8)

            try ZIPWriter.withArchive(at: archive) { writer in
                try writer.add(data: contents, path: "report.txt")
            }

            try ZIPReader.withArchive(at: archive) { reader in
                let actual = try reader.data(path: "report.txt")
                #expect(actual == contents)
            }
        }
    }

    @Test func `dangling alias beyond PATH_MAX is not followed when creating parents`() throws {
        try withLongDirectory { url, directory in
            try #require(symlinkat("missing", directory.raw, "alias") == 0)

            do {
                let opened = try FileSystem.openDirectory(url.appendingPathComponent("alias/nested"), createIntermediates: true)
                try opened.close(operation: .closeSourceDirectory, path: url.path)
                Issue.record("Expected the dangling alias to be rejected")
            } catch let ZIPError.fileSystem(operation, _, code) {
                #expect(operation == .openDirectory)
                #expect(code == ELOOP || code == ENOTDIR)
            }

            var info = stat()
            let result = fstatat(directory.raw, "missing", &info, AT_SYMLINK_NOFOLLOW)
            let lookupError = errno
            #expect(result == -1)
            #expect(lookupError == ENOENT)
        }
    }

    enum RestrictedLocation: CaseIterable {
        case prefix
        case remainingPath
    }

    @Test(.enabled(if: geteuid() != 0), arguments: RestrictedLocation.allCases, [false, true])
    func `long path traverses search only directories`(location: RestrictedLocation, createIntermediates: Bool) throws {
        try withLongDirectory { url, expected in
            try withRestrictedAncestor(of: url, directory: expected, location: location, permissions: 0o111) {
                let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
                #expect(try FileIdentity(opened) == FileIdentity(expected))
            }
        }
    }

    @Test(.enabled(if: geteuid() != 0), arguments: RestrictedLocation.allCases)
    func `long archive path creates parents through search only directories`(location: RestrictedLocation) throws {
        try withLongDirectory { url, directory in
            try withRestrictedAncestor(of: url, directory: directory, location: location, permissions: 0o111) {
                let archive = url.appendingPathComponent("exports/nested/resources.zip")
                let expected = Data("search only ancestor".utf8)

                try ZIPWriter.withArchive(at: archive) { writer in
                    try writer.add(data: expected, path: "report.txt")
                }

                try ZIPReader.withArchive(at: archive) { reader in
                    let actual = try reader.data(path: "report.txt")
                    #expect(actual == expected)
                }
            }
        }
    }

    @Test(.enabled(if: geteuid() != 0), arguments: RestrictedLocation.allCases)
    func `long path still requires traversal permission`(location: RestrictedLocation) throws {
        try withLongDirectory { url, directory in
            try withRestrictedAncestor(of: url, directory: directory, location: location, permissions: 0o400) {
                do {
                    let opened = try FileSystem.openDirectory(url, createIntermediates: true)
                    try opened.close(operation: .closeSourceDirectory, path: url.path)
                    Issue.record("Expected traversal without execute permission to fail")
                } catch let ZIPError.fileSystem(operation, _, code) {
                    #expect(operation == .openDirectory)
                    #expect(code == EACCES)
                }
            }
        }
    }

    @Test(.enabled(if: geteuid() != 0), arguments: [false, true])
    func `long path still requires read permission on the final directory`(createIntermediates: Bool) throws {
        try withLongDirectory { url, directory in
            var original = stat()
            try #require(fstat(directory.raw, &original) == 0)
            try #require(fchmod(directory.raw, 0o111) == 0)
            defer { fchmod(directory.raw, original.st_mode & 0o7777) }

            do {
                let opened = try FileSystem.openDirectory(url, createIntermediates: createIntermediates)
                try opened.close(operation: .closeSourceDirectory, path: url.path)
                Issue.record("Expected the unreadable final directory to be rejected")
            } catch let ZIPError.fileSystem(operation, path, code) {
                #expect(operation == .openDirectory)
                #expect(path == url.path)
                #expect(code == EACCES)
            }
        }
    }

    @Test func `long path lookup does not create missing directories`() throws {
        try withLongDirectory { url, directory in
            let missing = url.appendingPathComponent("missing/nested")
            do {
                let opened = try FileSystem.openDirectory(missing)
                try opened.close(operation: .closeSourceDirectory, path: missing.path)
                Issue.record("Expected the missing directory lookup to fail")
            } catch let ZIPError.fileSystem(operation, _, code) {
                #expect(operation == .openDirectory)
                #expect(code == ENOENT)
            }

            var info = stat()
            let result = fstatat(directory.raw, "missing", &info, AT_SYMLINK_NOFOLLOW)
            let lookupError = errno
            #expect(result == -1)
            #expect(lookupError == ENOENT)
        }
    }

    private func withRestrictedAncestor(
        of url: URL,
        directory: borrowing FileDescriptor,
        location: RestrictedLocation,
        permissions: mode_t,
        body: () throws -> Void,
    ) throws {
        var prefix = url
        var remainingComponents: [String] = []
        while prefix.path.utf8.count >= Int(PATH_MAX) {
            remainingComponents.append(prefix.lastPathComponent)
            prefix.deleteLastPathComponent()
        }

        let restrictedURL: URL = switch location {
        case .prefix:
            prefix

        case .remainingPath:
            try prefix.appendingPathComponent(#require(remainingComponents.last))
        }

        let depth = url.pathComponents.count - restrictedURL.pathComponents.count
        try #require(depth > 0)
        let relativePath = Array(repeating: "..", count: depth).joined(separator: "/")
        let restricted = try FileDescriptor(
            openat(directory.raw, relativePath, O_RDONLY | O_DIRECTORY | O_CLOEXEC),
            operation: .openDirectory,
            path: restrictedURL.path,
        )
        var original = stat()
        try #require(fstat(restricted.raw, &original) == 0)
        try #require(fchmod(restricted.raw, permissions) == 0)
        defer { fchmod(restricted.raw, original.st_mode & 0o7777) }

        // Check the actual permission boundary before exercising MagicZip.
        let probe = openat(directory.raw, relativePath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let probeError = errno
        if probe >= 0 {
            close(probe)
        }
        if permissions == 0o111 {
            try #require(probe == -1)
            try #require(probeError == EACCES)
        }

        try body()
    }

    private func withLongDirectory(_ body: (URL, borrowing FileDescriptor) throws -> Void) throws {
        try temporaryDirectory { root in
            let parent = try FileDescriptor(
                open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC),
                operation: .openDirectory,
                path: root.path,
            )
            let components = ["tree"] + (0 ..< 20).map { "directory-\($0)-" + String(repeating: "x", count: 50) }

            // Build and clean the fixture through descriptors, independently of openDirectory.
            defer {
                do {
                    try FileSystem.remove(parent: parent, name: "tree")
                } catch {
                    Issue.record(error)
                }
            }

            let directory = try FileSystem.directory(at: parent, components: components[...])
            let url = root.appendingPathComponent(components.joined(separator: "/"))
            try #require(url.path.utf8.count > Int(PATH_MAX))
            try body(url, directory)
        }
    }
}
