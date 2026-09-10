// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "QueryCraftDrivers",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "QueryCraftMySQLDriver",
            type: .dynamic,
            targets: ["QueryCraftMySQLDriver"]
        ),
        .library(
            name: "QueryCraftPostgreSQLDriver",
            type: .dynamic,
            targets: ["QueryCraftPostgreSQLDriver"]
        ),
        .library(
            name: "QueryCraftDorisDriver",
            type: .dynamic,
            targets: ["QueryCraftDorisDriver"]
        ),
        .library(
            name: "QueryCraftRedisDriver",
            type: .dynamic,
            targets: ["QueryCraftRedisDriver"]
        ),
        .library(
            name: "QueryCraftElasticsearchDriver",
            type: .dynamic,
            targets: ["QueryCraftElasticsearchDriver"]
        ),
    ],
    dependencies: [
        .package(path: "../QueryCraftPackage"),
    ],
    targets: [
        .systemLibrary(
            name: "CMariaDB",
            path: "Sources/CMariaDB"
        ),
        .systemLibrary(
            name: "CLibPQ",
            path: "Sources/CLibPQ"
        ),
        .target(
            name: "CHiredis",
            path: "Sources/CHiredis",
            publicHeadersPath: "include"
        ),
        .target(
            name: "QueryCraftMariaDBTransport",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
                "CMariaDB",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Libs",
                    "-lmariadb",
                    "-lssl",
                    "-lcrypto",
                    "-lz",
                ]),
            ]
        ),
        .target(
            name: "QueryCraftMySQLDriver",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
                "QueryCraftMariaDBTransport",
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ],
        ),
        .target(
            name: "QueryCraftDorisDriver",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
                "QueryCraftMariaDBTransport",
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        .target(
            name: "QueryCraftPostgreSQLDriver",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
                "CLibPQ",
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(Context.packageDirectory)/Libs",
                    "-lpq",
                    "-lpgcommon",
                    "-lpgport",
                    "-lssl",
                    "-lcrypto",
                    "-lz",
                ]),
            ]
        ),
        .target(
            name: "QueryCraftRedisDriver",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
                "CHiredis",
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        .target(
            name: "QueryCraftElasticsearchDriver",
            dependencies: [
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
        .testTarget(
            name: "QueryCraftMySQLDriverTests",
            dependencies: [
                "QueryCraftMySQLDriver",
                "QueryCraftMariaDBTransport",
                "CMariaDB",
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ]
        ),
        .testTarget(
            name: "QueryCraftPostgreSQLDriverTests",
            dependencies: [
                "QueryCraftPostgreSQLDriver",
                "CLibPQ",
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ]
        ),
        .testTarget(
            name: "QueryCraftDorisDriverTests",
            dependencies: [
                "QueryCraftDorisDriver",
                "QueryCraftMariaDBTransport",
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ]
        ),
        .testTarget(
            name: "QueryCraftRedisDriverTests",
            dependencies: [
                "QueryCraftRedisDriver",
                "CHiredis",
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ]
        ),
        .testTarget(
            name: "QueryCraftElasticsearchDriverTests",
            dependencies: [
                "QueryCraftElasticsearchDriver",
                .product(
                    name: "QueryCraftFeature",
                    package: "QueryCraftPackage"
                ),
            ]
        ),
    ]
)
