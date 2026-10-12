// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenStreamApple",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .visionOS(.v2),
    ],
    products: [
        .library(name: "OpenStreamApple", targets: ["OpenStreamApple"]),
    ],
    dependencies: [
        .package(url: "https://github.com/amosavian/AMSMB2", exact: "4.0.3"),
        .package(url: "https://github.com/cyberbanksy/AetherEngine", revision: "45d64e8a9b2ac422bcdb7f467f8327c214eab2ed"),
    ],
    targets: [
        .target(
            name: "OpenStreamApple",
            dependencies: [
                .product(
                    name: "AMSMB2",
                    package: "AMSMB2",
                    condition: .when(platforms: [.iOS, .macOS, .tvOS])
                ),
                .product(
                    name: "AetherEngine",
                    package: "AetherEngine"
                ),
            ],
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
                .copy("Resources/ChannelLineup"),
                .copy("Resources/ThirdPartyLicenses"),
                .copy("Resources/ThirdPartyNotices"),
                .copy("Resources/Badges"),
                .copy("Resources/Attribution"),
            ],
            swiftSettings: [.define("OPENSTREAM_ADDONS", .when(configuration: .debug))]
        ),
        // Release tool, not shipped: headless Stremio add-on compatibility sweep.
        // `swift run --scratch-path … OpenStreamAddonProbe sweep`
        .executableTarget(name: "OpenStreamAddonProbe", dependencies: ["OpenStreamApple"], swiftSettings: [.define("OPENSTREAM_ADDONS", .when(configuration: .debug))]),
        .testTarget(name: "OpenStreamAppleTests", dependencies: ["OpenStreamApple"], swiftSettings: [.define("OPENSTREAM_ADDONS", .when(configuration: .debug))]),
    ]
)
