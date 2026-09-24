// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HidiPi",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HidiPiCore"),
        .target(name: "HidiPiIcon", dependencies: []),
        .executableTarget(
            name: "HidiPi",
            dependencies: ["HidiPiCore", "HidiPiIcon"]
        ),
        .executableTarget(
            name: "render-icon",
            dependencies: ["HidiPiIcon"]
        ),
        .testTarget(
            name: "HidiPiCoreTests",
            dependencies: ["HidiPiCore"]
        ),
    ]
)
