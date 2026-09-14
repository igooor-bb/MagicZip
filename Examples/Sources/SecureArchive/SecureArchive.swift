import Foundation
import MagicZip

@main
struct SecureArchive {
    static func main() async throws {
        print("Protect file contents, names and timestamps with a secure archive")
        print("This example uses temporary files that are removed when it finishes.\n")

        let files = FileManager.default
        let workspace = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: workspace) }

        let inputText = "Confidential report.\n"
        let inputData = Data(inputText.utf8)
        print("Input private/report.txt: \(inputText.debugDescription)\n")

        let archive = workspace.appendingPathComponent("secure.zip")
        // For demonstration only. Obtain the password from the user or secure storage in an app.
        let password = "example-password"

        // Secure archives also protect names and timestamps and require a compatible reader.
        try await SecureZIPWriter.withArchiveAsync(at: archive, password: password) { writer in
            try writer.add(data: inputData, path: "private/report.txt")
        }

        print("Created secure.zip with encrypted contents, names and timestamps.")
        print("Reading this format requires a compatible reader such as SecureZIPReader.")

        let output = workspace.appendingPathComponent("extracted")
        let entries = try await SecureZIPReader.withArchiveAsync(at: archive, password: password) { reader in
            print("Opened the protected catalog using the password.")
            let contents = try reader.data(path: "private/report.txt")
            if let text = String(data: contents, encoding: .utf8) {
                print("Read private/report.txt: \(text.debugDescription)")
            }

            guard contents == inputData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            print("PASS: decrypted contents match the input byte for byte.")

            try reader.extract(to: output, selection: .subtree("private"))
            return reader.entries
        }
        print("Extracted the private/ folder. Protected catalog entries (\(entries.count)):")
        for entry in entries {
            print("  - \(entry.path)")
        }
        let extracted = try Data(contentsOf: output.appendingPathComponent("private/report.txt"))
        if let text = String(data: extracted, encoding: .utf8) {
            print("Extracted private/report.txt: \(text.debugDescription)")
        }
        guard extracted == inputData else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS: the extracted file matches the input byte for byte.\n")
    }
}
