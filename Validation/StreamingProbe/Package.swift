// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StreamingProbe", platforms: [.macOS(.v13)], dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "StreamingProbe", dependencies: [.product(name: "MagicZip", package: "MagicZip")])],
)
