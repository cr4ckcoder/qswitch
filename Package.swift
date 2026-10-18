// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "qswitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "qswitch", path: "Sources/qswitch")
    ]
)
