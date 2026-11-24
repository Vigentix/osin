// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsinCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OsinCore", targets: ["OsinCore"])
    ],
    targets: [
        .target(name: "OsinCore"),
        .testTarget(name: "OsinCoreTests", dependencies: ["OsinCore"])
    ]
)
