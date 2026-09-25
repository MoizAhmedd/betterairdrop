// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "betterairdrop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "betterairdrop", targets: ["betterairdrop"]),
        .executable(name: "BetterAirdrop", targets: ["BetterAirdropApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
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
                "BetterAirdropKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Logic behind the menu-bar app that doesn't need a UI (and is unit-tested): pause
        // schedules, notification text, recent rows, the CLI link, the uninstaller.
        .target(name: "BetterAirdropKit", dependencies: ["BetterAirdropCore"]),
        // The menu-bar app. Built into BetterAirdrop.app by scripts/make-app.sh.
        .executableTarget(
            name: "BetterAirdropApp",
            dependencies: [
                "BetterAirdropCore",
                "BetterAirdropKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Packs GeoNames cities15000.txt into Resources/cities.bin. See scripts/update-cities.sh.
        .executableTarget(name: "betterairdrop-pack-cities", dependencies: ["BetterAirdropCore"]),
        .testTarget(name: "BetterAirdropCoreTests", dependencies: ["BetterAirdropCore"]),
        .testTarget(name: "BetterAirdropKitTests", dependencies: ["BetterAirdropKit"]),
    ]
)
