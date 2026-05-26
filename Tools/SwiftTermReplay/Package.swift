// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftTermReplay",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "swiftterm-replay", targets: ["SwiftTermReplay"])
    ],
    dependencies: [
        // Same fork as main Logos app
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftTermReplay",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
