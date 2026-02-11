// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cauth",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "cauth", targets: ["cauth"]),
    ],
    targets: [
        .executableTarget(
            name: "cauth",
            path: "Sources"
        ),
        .testTarget(
            name: "cauthTests",
            dependencies: ["cauth"],
            path: "Tests"
        ),
    ]
)
