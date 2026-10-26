// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeptuneControl",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NeptuneControl", targets: ["NeptuneControl"])],
    targets: [
        .target(name: "NeptuneControlCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "NeptuneControl", dependencies: ["NeptuneControlCore"]),
        .testTarget(name: "NeptuneControlCoreTests", dependencies: ["NeptuneControlCore"])
    ]
)
