// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Caesura",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Caesura", targets: ["CaesuraApp"]),
        .executable(name: "caesura-cli", targets: ["caesura-cli"]),
        .library(name: "CaesuraCore", targets: ["CaesuraCore"])
    ],
    targets: [
        .target(
            name: "CaesuraCore",
            path: "native/Sources/CaesuraCore",
            resources: [
                .copy("Resources/locales"),
                .copy("Resources/poems")
            ]
        ),
        .executableTarget(
            name: "CaesuraApp",
            dependencies: ["CaesuraCore"],
            path: "native/Sources/CaesuraApp"
        ),
        .executableTarget(
            name: "caesura-cli",
            dependencies: ["CaesuraCore"],
            path: "native/Sources/caesura-cli"
        ),
        .executableTarget(
            name: "caesura-core-tests",
            dependencies: ["CaesuraCore"],
            path: "native/Tests/CaesuraCoreTests"
        )
    ]
)
