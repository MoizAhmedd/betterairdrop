// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "betterairdrop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "betterairdrop", targets: ["betterairdrop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "BetterAirdropCore",
            resources: [.copy("Resources/cities.bin")]
        ),
        .executableTarget(
            name: "betterairdrop",
            dependencies: [
                "BetterAirdropCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Packs GeoNames cities15000.txt into Resources/cities.bin. See scripts/update-cities.sh.
        .executableTarget(name: "betterairdrop-pack-cities", dependencies: ["BetterAirdropCore"]),
        .testTarget(name: "BetterAirdropCoreTests", dependencies: ["BetterAirdropCore"]),
    ]
)
