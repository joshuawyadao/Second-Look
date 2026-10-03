// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecondLookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SecondLookCore", targets: ["SecondLookCore"])],
    targets: [
        .target(name: "SecondLookCore", path: "SecondLookCore"),
        .testTarget(name: "SecondLookCoreTests", dependencies: ["SecondLookCore"], path: "SecondLookCoreTests"),
    ]
)
