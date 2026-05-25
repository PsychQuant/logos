// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Logos",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Logos", targets: ["Logos"])
    ],
    targets: [
        .executableTarget(
            name: "Logos"
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        )
    ]
)
