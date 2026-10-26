// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "QueryCraftSSHTerminalRenderer",
    platforms: [.macOS(.v15)],
    products: [.library(name: "QueryCraftSSHTerminalRenderer", type: .dynamic, targets: ["QueryCraftSSHTerminalRenderer"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1")],
    targets: [
        .systemLibrary(name: "CQueryCraftSSHTerminalRendererAPI"),
        .target(name: "QueryCraftSSHTerminalRenderer", dependencies: ["CQueryCraftSSHTerminalRendererAPI", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "QueryCraftSSHTerminalRendererTests", dependencies: ["QueryCraftSSHTerminalRenderer", "CQueryCraftSSHTerminalRendererAPI", .product(name: "SwiftTerm", package: "SwiftTerm")])
    ]
)
