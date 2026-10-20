// swift-tools-version: 6.1
import PackageDescription

// A separate package lets both driver products depend on the dynamic product,
// instead of SwiftPM statically embedding a same-package target in each plugin.
let package = Package(
    name: "QueryCraftMariaDBTransport",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "QueryCraftMariaDBTransportV3", type: .dynamic, targets: ["QueryCraftMariaDBTransportV3"]),
        .library(name: "CMariaDB", targets: ["CMariaDB"]),
    ],
    dependencies: [.package(path: "../../QueryCraftPackage")],
    targets: [
        .systemLibrary(name: "CMariaDB"),
        .target(
            name: "QueryCraftMariaDBTransportV3",
            dependencies: [
                .product(name: "QueryCraftFeature", package: "QueryCraftPackage"),
                "CMariaDB",
            ],
            path: "Sources/QueryCraftMariaDBTransport",
            linkerSettings: [.unsafeFlags([
                "-L\(Context.packageDirectory)/../Libs", "-lmariadb", "-lssl", "-lcrypto", "-lz",
            ])]
        ),
    ]
)
