// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "RainbarrelCore", targets: ["RainbarrelCore"]),
    .executable(name: "rainbarrel", targets: ["rainbarrel"]),
]

var targets: [Target] = [
    // System SQLite for Linux. macOS uses the SQLite3 module from the SDK.
    .systemLibrary(
        name: "CSQLite",
        pkgConfig: "sqlite3",
        providers: [.apt(["libsqlite3-dev"])]
    ),
    .target(
        name: "RainbarrelCore",
        dependencies: [
            .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        ]
    ),
    .executableTarget(
        name: "rainbarrel",
        dependencies: [
            "RainbarrelCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "MCP", package: "swift-sdk"),
        ]
    ),
    .testTarget(
        name: "RainbarrelCoreTests",
        dependencies: ["RainbarrelCore"]
    ),
]

#if os(macOS)
// The menu-bar app is macOS only; Linux builds skip it.
products.append(.executable(name: "RainbarrelBar", targets: ["RainbarrelBar"]))
targets.append(
    .executableTarget(
        name: "RainbarrelBar",
        dependencies: ["RainbarrelCore"]
    )
)
#endif

let package = Package(
    name: "Rainbarrel",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto", from: "5.0.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: targets
)
