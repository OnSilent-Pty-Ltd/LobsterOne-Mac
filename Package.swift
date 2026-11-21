// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LobsterOne",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "LobsterOne",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/LobsterOne",
            exclude: ["Resources/Info.plist", "Resources/LobsterOne.entitlements"],
            resources: [.copy("Resources/Fonts"), .copy("Resources/ScreensaverStyles"), .copy("Resources/Garry"), .copy("Resources/Packs"), .copy("Resources/Sounds"), .copy("Resources/Crew")]
        ),
        .testTarget(
            name: "LobsterOneTests",
            dependencies: ["LobsterOne"],
            path: "Tests/LobsterOneTests"
        ),
    ]
)
