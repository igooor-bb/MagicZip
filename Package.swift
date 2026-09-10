// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MagicZip",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "MagicZip", targets: ["MagicZip"])],
    targets: [
        .target(
            name: "CMinizip",
            exclude: ["vendor/LICENSE", "vendor/METADATA.json"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("z"), .linkedFramework("Security")],
        ),
        .target(name: "MagicZip", dependencies: ["CMinizip"]),
        .target(name: "CMinizipTestSupport", dependencies: ["CMinizip"], path: "Tests/CMinizipTestSupport", publicHeadersPath: "include"),
        .testTarget(name: "MagicZipTests", dependencies: ["MagicZip", "CMinizipTestSupport"], resources: [.copy("Fixtures")]),
    ],
)
