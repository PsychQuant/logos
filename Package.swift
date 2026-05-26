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
    dependencies: [
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base")
    ],
    targets: [
        .executableTarget(
            name: "Logos",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        )
    ]
)
