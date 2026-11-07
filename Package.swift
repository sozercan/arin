// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Arin",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "ArinApp", targets: ["ArinApp"]),
        .executable(name: "arin", targets: ["ArinCLI"]),
        .library(name: "ArinCore", targets: ["ArinCore"]),
    ],
    targets: [
        .target(name: "ArinCore"),
        .executableTarget(
            name: "ArinApp",
            dependencies: ["ArinCore"],
            // Compiled into the app bundle by Scripts/build-app.sh with actool.
            exclude: ["Resources/AppIcon.icon"]
        ),
        .executableTarget(name: "ArinCLI", dependencies: ["ArinCore"], path: "Sources/arin-cli"),
        .testTarget(name: "ArinCoreTests", dependencies: ["ArinCore"]),
    ]
)
