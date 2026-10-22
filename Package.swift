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
        .package(path: "../../kindle-toolkit/packages/ax-driver")
    ],
    targets: [
        .target(
            name: "TsundokuCore",
            dependencies: [.product(name: "KindleAX", package: "ax-driver")]
        ),
        .target(name: "TsundokuUI", dependencies: ["TsundokuCore"]),
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
                .product(name: "KindleAX", package: "ax-driver"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
