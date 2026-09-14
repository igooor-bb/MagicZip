import Foundation
import MagicZip

@main
struct CreateAndExtract {
    static func main() throws {
        print("Create and extract a ZIP archive")
        print("This example uses temporary files that are removed when it finishes.\n")

        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        let greetingText = "Hello from MagicZip!\n"
        let notesText = "A sample document.\n"
        let greetingData = Data(greetingText.utf8)
        let notesData = Data(notesText.utf8)
        print("Input:")
        print("  hello.txt: \(greetingText.debugDescription)")
        print("  documents/notes.txt: \(notesText.debugDescription)\n")

        // Prepare a small source folder so the example runs without external files.
        let documents = workspace.appendingPathComponent("documents")
        try files.createDirectory(at: documents, withIntermediateDirectories: false)
        try notesData.write(to: documents.appendingPathComponent("notes.txt"))
        let archive = workspace.appendingPathComponent("example.zip")

        try ZIPWriter.withArchive(at: archive) { writer in
            try writer.add(data: greetingData, path: "hello.txt", compression: .store)
            try writer.add(directory: documents, path: "documents", compression: .deflate(level: .balanced))
        }

        print("Created example.zip from a greeting and a documents folder.")

        try ZIPReader.withArchive(at: archive) { reader in
            print("Archive entries:")
            for entry in reader.entries {
                print("  - \(entry.path)")
            }

            let greeting = try reader.data(path: "hello.txt")
            if let text = String(data: greeting, encoding: .utf8) {
                print("\nRead hello.txt: \(text.debugDescription)")
            }

            guard greeting == greetingData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            print("PASS: hello.txt matches the input byte for byte.")

            // Select a folder without extracting the other entries.
            let output = workspace.appendingPathComponent("extracted")
            try reader.extract(to: output, selection: .subtree("documents"))
            let notes = try Data(contentsOf: output.appendingPathComponent("documents/notes.txt"))
            if let text = String(data: notes, encoding: .utf8) {
                print("Extracted documents/notes.txt: \(text.debugDescription)")
            }
            guard notes == notesData, !files.fileExists(atPath: output.appendingPathComponent("hello.txt").path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            print("PASS: documents/notes.txt matches the input byte for byte.")
            print("PASS: hello.txt was excluded from extraction.")
        }
    }
}
