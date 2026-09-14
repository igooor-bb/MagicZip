// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StreamingMemoryTests",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "StreamingMemoryTests", dependencies: [.product(name: "MagicZip", package: "MagicZip")])],
)
