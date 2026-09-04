// swift-tools-version: 6.0
// SwiftUI app. Dev: `cd macos && swift run`. Release: scripts/build-app.sh.
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
