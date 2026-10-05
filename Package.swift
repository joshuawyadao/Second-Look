// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecondLookCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SecondLookCore", targets: ["SecondLookCore"]),
        .library(name: "SecondLookTransport", targets: ["SecondLookTransport"]),
    ],
    targets: [
        .target(name: "SecondLookCore", path: "SecondLookCore"),
        .target(name: "SecondLookTransport", dependencies: ["SecondLookCore"],
                path: "SecondLook/Services/Transport"),
        .testTarget(name: "SecondLookCoreTests", dependencies: ["SecondLookCore"], path: "SecondLookCoreTests"),
    ]
)
