// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParallaxKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ParallaxCore", targets: ["ParallaxCore"])
    ],
    targets: [
        .target(name: "ParallaxCore"),
        .testTarget(name: "ParallaxCoreTests", dependencies: ["ParallaxCore"])
    ]
)
