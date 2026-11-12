// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HumminMenubar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FleetCore", path: "Sources/FleetCore"),
        .executableTarget(
            name: "HumminMenubar",
            dependencies: ["FleetCore"],
            path: "Sources/HumminMenubar",
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "FleetCoreTests", dependencies: ["FleetCore"], path: "Tests/FleetCoreTests"),
    ]
)
