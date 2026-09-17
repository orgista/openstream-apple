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
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "6.66.0"),
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
                .copy("Resources/ThirdPartyLicenses"),
                .copy("Resources/ThirdPartyNotices"),
                .copy("Resources/ChannelLineup"),
                .copy("Resources/Badges"),
            ]
        ),
        .testTarget(name: "OpenStreamAppleTests", dependencies: ["OpenStreamApple"]),
    ]
)
