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
        .package(url: "https://github.com/orgista/AetherEngine", revision: "ba92a697151584fb93a6c9d77b455b7540d90835"),
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
                .copy("Resources/ThirdPartyLicenses"),
                .copy("Resources/ThirdPartyNotices"),
                .copy("Resources/Attribution"),
            ]
        ),
        .testTarget(name: "OpenStreamAppleTests", dependencies: ["OpenStreamApple"]),
    ]
)
