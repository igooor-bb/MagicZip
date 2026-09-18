import Darwin
import Foundation
import MagicZip
import Testing

/// Root bypasses POSIX permission checks, so it cannot exercise these regressions.
@Suite(.enabled(if: geteuid() != 0))
struct FileSystemAccessTests {
    enum ArchiveFormat: CaseIterable {
        case zip
        case secureZIP
    }

    enum SourceKind: CaseIterable {
        case file
        case directory
    }

    @Test(arguments: ArchiveFormat.allCases)
    func `reader opens an archive through a search only ancestor`(format: ArchiveFormat) throws {
        try temporaryDirectory { root in
            let container = try makeContainer(in: root)
            let archive = container.appendingPathComponent("resources.bundle")
            let contents = ["private/report.txt": Data("report contents".utf8)]
            try writeArchive(at: archive, format: format, contents: contents)

            try withSearchOnlyAncestor(of: container) {
                try #require(!Data(contentsOf: archive).isEmpty)
                #expect(try readArchive(at: archive, format: format) == contents)
            }
        }
    }

    @Test(arguments: ArchiveFormat.allCases)
    func `reader extracts selected entries through a search only destination ancestor`(format: ArchiveFormat) throws {
        try temporaryDirectory { root in
            let container = try makeContainer(in: root)
            let archive = root.appendingPathComponent("input.zip")
            let destination = container.appendingPathComponent("cache/modules/output")
            let expected = Data("selected contents".utf8)
            try writeArchive(at: archive, format: format, contents: [
                "private/report.txt": expected,
                "public.txt": Data("unselected contents".utf8),
            ])

            try withSearchOnlyAncestor(of: container) {
                switch format {
                case .zip:
                    try ZIPReader.withArchive(at: archive) { reader in
                        try reader.extract(to: destination, selection: .subtree("private"))
                    }

                case .secureZIP:
                    try SecureZIPReader.withArchive(at: archive, password: "password") { reader in
                        try reader.extract(to: destination, selection: .subtree("private"))
                    }
                }

                #expect(try Data(contentsOf: destination.appendingPathComponent("private/report.txt")) == expected)
                #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("public.txt").path))
            }
        }
    }

    @Test(arguments: ArchiveFormat.allCases)
    func `writer creates an archive through a search only destination ancestor`(format: ArchiveFormat) throws {
        try temporaryDirectory { root in
            let container = try makeContainer(in: root)
            let archive = container.appendingPathComponent("archives/nested/output.zip")
            let contents = ["report.txt": Data("written contents".utf8)]

            try withSearchOnlyAncestor(of: container) {
                try writeArchive(at: archive, format: format, contents: contents)
            }

            #expect(try readArchive(at: archive, format: format) == contents)
        }
    }

    @Test(arguments: ArchiveFormat.allCases, SourceKind.allCases)
    func `writer adds a source through a search only ancestor`(format: ArchiveFormat, sourceKind: SourceKind) throws {
        try temporaryDirectory { root in
            let container = try makeContainer(in: root)
            let sourceDirectory = container.appendingPathComponent("source")
            let sourceFile = sourceDirectory.appendingPathComponent("report.txt")
            let archive = root.appendingPathComponent("output.zip")
            let expected = Data("source contents".utf8)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
            try expected.write(to: sourceFile)

            try withSearchOnlyAncestor(of: container) {
                switch format {
                case .zip:
                    try ZIPWriter.withArchive(at: archive) { writer in
                        switch sourceKind {
                        case .file:
                            try writer.add(file: sourceFile, path: "copied/report.txt")

                        case .directory:
                            try writer.add(directory: sourceDirectory, path: "copied")
                        }
                    }

                case .secureZIP:
                    try SecureZIPWriter.withArchive(at: archive, password: "password") { writer in
                        switch sourceKind {
                        case .file:
                            try writer.add(file: sourceFile, path: "copied/report.txt")

                        case .directory:
                            try writer.add(directory: sourceDirectory, path: "copied")
                        }
                    }
                }
            }

            #expect(try readArchive(at: archive, format: format) == ["copied/report.txt": expected])
        }
    }

    private func makeContainer(in root: URL) throws -> URL {
        let container = root.appendingPathComponent("containers/application")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        return container
    }

    private func withSearchOnlyAncestor(of container: URL, body: () throws -> Void) throws {
        let parent = container.deletingLastPathComponent()

        // Retain traversal permission, but reject opening the ancestor for reading.
        try #require(chmod(parent.path, 0o111) == 0)
        defer { chmod(parent.path, 0o755) }

        let parentDescriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let parentError = errno
        if parentDescriptor >= 0 {
            close(parentDescriptor)
        }
        try #require(parentDescriptor == -1)
        try #require(parentError == EACCES)

        // Confirm that opening the allowed directory directly still works.
        let containerDescriptor = open(container.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(containerDescriptor >= 0)
        defer { close(containerDescriptor) }

        try body()
    }

    private func writeArchive(at archive: URL, format: ArchiveFormat, contents: [String: Data]) throws {
        switch format {
        case .zip:
            try ZIPWriter.withArchive(at: archive) { writer in
                for (path, data) in contents {
                    try writer.add(data: data, path: path)
                }
            }

        case .secureZIP:
            try SecureZIPWriter.withArchive(at: archive, password: "password") { writer in
                for (path, data) in contents {
                    try writer.add(data: data, path: path)
                }
            }
        }
    }

    private func readArchive(at archive: URL, format: ArchiveFormat) throws -> [String: Data] {
        switch format {
        case .zip:
            try ZIPReader.withArchive(at: archive) { reader in
                var contents: [String: Data] = [:]
                for entry in reader.entries where !entry.isDirectory {
                    contents[entry.path] = try reader.data(path: entry.path)
                }
                return contents
            }

        case .secureZIP:
            try SecureZIPReader.withArchive(at: archive, password: "password") { reader in
                var contents: [String: Data] = [:]
                for entry in reader.entries where !entry.isDirectory {
                    contents[entry.path] = try reader.data(path: entry.path)
                }
                return contents
            }
        }
    }
}
