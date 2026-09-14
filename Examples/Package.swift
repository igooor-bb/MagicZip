// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MagicZipExamples",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: [
        .executableTarget(name: "CreateAndExtract", dependencies: [.product(name: "MagicZip", package: "MagicZip")]),
        .executableTarget(name: "PasswordProtectedArchive", dependencies: [.product(name: "MagicZip", package: "MagicZip")]),
        .executableTarget(name: "SecureArchive", dependencies: [.product(name: "MagicZip", package: "MagicZip")]),
    ],
)
