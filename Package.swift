// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kindling",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kindling", targets: ["KindlingApp"]),
        .executable(name: "kindling-cli", targets: ["KindlingCLI"]),
    ],
    dependencies: [
        .package(path: "../../kindle-toolkit/packages/ax-driver")
    ],
    targets: [
        .target(
            name: "KindlingCore",
            dependencies: [.product(name: "KindleAX", package: "ax-driver")]
        ),
        .target(name: "KindlingUI", dependencies: ["KindlingCore"]),
        .executableTarget(
            name: "KindlingApp",
            dependencies: ["KindlingCore", "KindlingUI"]
        ),
        .executableTarget(
            name: "KindlingCLI",
            dependencies: ["KindlingCore"]
        ),
        .testTarget(
            name: "KindlingTests",
            dependencies: ["KindlingCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
