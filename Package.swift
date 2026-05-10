// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DiskViz",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DiskViz", targets: ["DiskViz"])
    ],
    targets: [
        .executableTarget(
            name: "DiskViz",
            path: "Sources/DiskViz"
        ),
        .testTarget(
            name: "DiskVizTests",
            dependencies: ["DiskViz"],
            path: "Tests/DiskVizTests"
        )
    ]
)
