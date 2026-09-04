// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cookbook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Cookbook", targets: ["Cookbook"])
    ],
    targets: [
        .executableTarget(
            name: "Cookbook",
            path: "Sources/Cookbook",
            resources: [
                .copy("Resources/strings.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
