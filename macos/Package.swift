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
        .target(
            name: "LibMobi",
            path: "Sources/LibMobi",
            exclude: ["COPYING", "NOTICE"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("HAVE_STRDUP"),
                .define("PACKAGE_VERSION", to: "\"0.12\""),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .target(
            name: "CookbookWebKit",
            path: "Sources/CookbookWebKit",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "Cookbook",
            dependencies: ["CookbookWebKit", "LibMobi"],
            path: "Sources/Cookbook",
            resources: [
                .copy("Resources/strings.json")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("PDFKit"),
            ]
        )
    ]
)
