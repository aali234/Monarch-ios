// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MonarchCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "MonarchCore", targets: ["MonarchCore"])],
    targets: [
        .target(name: "MonarchCore"),
        .testTarget(name: "MonarchCoreTests", dependencies: ["MonarchCore"])
    ]
)
