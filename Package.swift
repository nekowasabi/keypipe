// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "keypipe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "keypipe"),
        .testTarget(name: "keypipeTests", dependencies: ["keypipe"]),
    ]
)
