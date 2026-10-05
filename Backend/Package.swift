// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SecondLookBackend",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SecondLookServer", targets: ["SecondLookServer"])],
    dependencies: [
        .package(name: "SecondLookCore", path: ".."),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
    ],
    targets: [
        .executableTarget(name: "SecondLookServer", dependencies: [
            .product(name: "Vapor", package: "vapor"),
            .product(name: "SecondLookCore", package: "SecondLookCore"),
        ]),
        .testTarget(name: "SecondLookServerTests", dependencies: [
            "SecondLookServer",
            .product(name: "VaporTesting", package: "vapor"),
            .product(name: "SecondLookTransport", package: "SecondLookCore"),
        ]),
    ]
)
