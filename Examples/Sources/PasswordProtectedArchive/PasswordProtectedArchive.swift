import Foundation
import MagicZip

@main
struct PasswordProtectedArchive {
    static func main() async throws {
        print("Read and extract a password-protected ZIP archive")
        print("This example uses temporary files that are removed when it finishes.\n")

        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        let inputText = "Private notes.\n"
        let inputData = Data(inputText.utf8)
        print("Input notes.txt: \(inputText.debugDescription)\n")

        let archive = workspace.appendingPathComponent("protected.zip")
        // For demonstration only. Obtain the password from the user or secure storage in an app.
        let password = "example-password"

        // One password encrypts every file's contents. Names remain visible in ordinary ZIP archives.
        try await ZIPWriter.withArchiveAsync(at: archive, password: password) { writer in
            try writer.add(data: inputData, path: "notes.txt")
        }

        print("Created protected.zip with encrypted file contents. File names remain visible.")

        let contents = try await ZIPReader.withArchiveAsync(at: archive) { reader in
            try reader.data(path: "notes.txt", password: password)
        }
        if let text = String(data: contents, encoding: .utf8) {
            print("Read notes.txt using the password: \(text.debugDescription)")
        }

        guard contents == inputData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS: decrypted contents match the input byte for byte.")

        let output = workspace.appendingPathComponent("extracted")
        let entries = try await ZIPReader.withArchiveAsync(at: archive) { reader in
            try reader.extract(to: output, password: password)
            return reader.entries
        }
        print("Extracted archive entries using the password (\(entries.count)):")
        for entry in entries {
            print("  - \(entry.path)")
        }
        let extracted = try Data(contentsOf: output.appendingPathComponent("notes.txt"))
        if let text = String(data: extracted, encoding: .utf8) {
            print("Extracted notes.txt: \(text.debugDescription)")
        }
        guard extracted == inputData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS: the extracted file matches the input byte for byte.\n")
    }
}
