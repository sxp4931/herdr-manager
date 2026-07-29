// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrManagerCore", targets: ["HerdrManagerCore"]),
        .executable(name: "herdmgr", targets: ["herdmgr"]),
        .executable(name: "HerdrManagerApp", targets: ["HerdrManagerApp"]),
        .executable(name: "herdr-manager-mcp", targets: ["herdr-manager-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "HerdrManagerCore",
            path: "Sources/HerdrManagerCore"
        ),
        .executableTarget(
            name: "herdmgr",
            dependencies: [
                "HerdrManagerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/herdmgr"
        ),
        .executableTarget(
            name: "HerdrManagerApp",
            dependencies: ["HerdrManagerCore"],
            path: "Sources/HerdrManagerApp"
        ),
        .executableTarget(
            name: "herdr-manager-mcp",
            dependencies: ["HerdrManagerCore"],
            path: "Sources/herdr-manager-mcp"
        ),
        .testTarget(
            name: "HerdrManagerCoreTests",
            dependencies: ["HerdrManagerCore"],
            path: "Tests/HerdrManagerCoreTests"
        ),
    ]
)
