// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompatibilityValidation",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/ZipArchive/ZipArchive.git", exact: "2.5.5"),
    ],
    targets: [.executableTarget(name: "CompatibilityValidation", dependencies: [
        .product(name: "MagicZip", package: "MagicZip"),
        .product(name: "ZipArchive", package: "ZipArchive"),
    ])],
)
