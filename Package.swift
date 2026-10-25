// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tsundoku",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Tsundoku", targets: ["TsundokuApp"]),
        .executable(name: "tsundoku-cli", targets: ["TsundokuCLI"]),
    ],
    dependencies: [
        .package(path: "vendor/kindle-toolkit/packages/ax-driver"),
        .package(path: "vendor/sayso"),
    ],
    targets: [
        .target(
            name: "TsundokuCore",
            dependencies: [
                .product(name: "KindleAX", package: "ax-driver"),
                .product(name: "SaySoAI", package: "sayso"),
                .product(name: "SaySoAICLI", package: "sayso"),
                .product(name: "SaySoAIApple", package: "sayso"),
            ]
        ),
        .target(
            name: "TsundokuUI",
            dependencies: [
                "TsundokuCore",
                .product(name: "SaySoAI", package: "sayso"),
            ]
        ),
        .executableTarget(
            name: "TsundokuApp",
            dependencies: ["TsundokuCore", "TsundokuUI"]
        ),
        .executableTarget(
            name: "TsundokuCLI",
            dependencies: ["TsundokuCore"]
        ),
        .testTarget(
            name: "TsundokuTests",
            dependencies: [
                "TsundokuCore",
                "TsundokuUI",
                .product(name: "KindleAX", package: "ax-driver"),
                .product(name: "SaySoAI", package: "sayso"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
