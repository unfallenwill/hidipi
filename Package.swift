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
        .testTarget(
            name: "HidiPiIconTests",
            dependencies: ["HidiPiIcon"]
        ),
        .testTarget(
            name: "HidiPiTests",
            dependencies: ["HidiPi"]
        ),
        // Real CG transactions against live displays — only safe on disposable machines
        // (CI runners); gated by HIDIPI_INTEGRATION=1, local `swift test` skips them.
        .testTarget(
            name: "HidiPiIntegrationTests",
            dependencies: ["HidiPi"]
        ),
    ]
)
