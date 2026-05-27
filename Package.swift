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
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1")
    ],
    targets: [
        .executableTarget(
            name: "Logos",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr")
            ]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        )
    ]
)
