// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "airname",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "airname", targets: ["airname"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AirnameCore",
            resources: [.copy("Resources/cities.bin")]
        ),
        .executableTarget(
            name: "airname",
            dependencies: [
                "AirnameCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Packs GeoNames cities15000.txt into Resources/cities.bin. See scripts/update-cities.sh.
        .executableTarget(name: "airname-pack-cities", dependencies: ["AirnameCore"]),
        .testTarget(name: "AirnameCoreTests", dependencies: ["AirnameCore"]),
    ]
)
