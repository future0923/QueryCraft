// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "QueryCraftMCP",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "querycraft-mcp", targets: ["QueryCraftMCPExecutable"])],
    dependencies: [
        // Refer to the dynamic product, not its target: drivers and MCP must
        // resolve their shared types and registry to exactly one Feature image.
        .package(path: "../QueryCraftPackage"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", revision: "a0ae212ebf6eab5f754c3129608bc5557637e605"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "QueryCraftMCPRuntime", dependencies: [
            .product(name: "QueryCraftFeature", package: "QueryCraftPackage"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .executableTarget(name: "QueryCraftMCPExecutable", dependencies: [
            "QueryCraftMCPRuntime",
            .product(name: "QueryCraftFeature", package: "QueryCraftPackage"),
        ]),
        .testTarget(name: "QueryCraftMCPTests", dependencies: [
            "QueryCraftMCPRuntime",
            .product(name: "QueryCraftFeature", package: "QueryCraftPackage"),
            .product(name: "MCP", package: "swift-sdk"),
        ]),
    ]
)
