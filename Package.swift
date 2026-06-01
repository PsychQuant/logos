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
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Logos",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        ),
        // Track A headless smoke / E2E (testing-smoke-e2e-strategy). The pure
        // UnifiedLogReader parse test runs in any `swift test`; the app-launching
        // SmokeTests are gated behind the LOGOS_SMOKE env var (set by `make smoke`)
        // so a plain `swift test` never launches the bundled app.
        .testTarget(
            name: "LogosSmokeTests",
            dependencies: ["Logos"]
        )
    ]
)
