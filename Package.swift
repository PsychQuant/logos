// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Logos",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Logos", targets: ["Logos"]),
        // #34: first-party-safe claude multi-account switching + auth, as a
        // LAUNCHER. UI-free; links Foundation + os only — NOT Security (so a
        // keychain call is a compile error, enforced by RedLineAuditTests).
        .library(name: "LogoSwitch", targets: ["LogoSwitch"]),
        // merge-multistats-into-logos: the standalone multi-account usage
        // viewer, retained as a thin product of the merged package.
        .executable(name: "MultiStats", targets: ["MultiStats"])
    ],
    dependencies: [
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.2.1"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        // merge-multistats-into-logos — credential-free account registry layer:
        // account model, config-dir convention, filesystem discovery, config-JSON
        // identity parsing. Foundation-only; covered by the red-line audit scan.
        .target(name: "LogosAccounts"),

        // merge-multistats-into-logos — the ONLY target permitted to import
        // Security. Read-only Keychain credential reads (SecItemCopyMatching
        // only — writes are forbidden package-wide by audit test), usage API
        // client, per-account usage view model.
        .target(name: "LogosUsage", dependencies: ["LogosAccounts"]),

        // #34 — UI-free launcher + auth core. Depends only on LogosAccounts
        // (itself Foundation-only) beyond the stdlib (Foundation + os). Must NOT
        // import Security or link any framework that exposes keychain/credential
        // APIs (enforced by RedLineAuditTests).
        .target(name: "LogoSwitch", dependencies: ["LogosAccounts"]),

        .executableTarget(
            name: "Logos",
            dependencies: [
                "LogoSwitch",
                "LogosAccounts",
                "LogosUsage",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Yams", package: "Yams")
            ]
        ),

        // merge-multistats-into-logos — thin standalone viewer executable
        // (SwiftUI shell over LogosUsage).
        .executableTarget(
            name: "MultiStats",
            dependencies: ["LogosAccounts", "LogosUsage"]
        ),
        .testTarget(
            name: "LogoSwitchTests",
            dependencies: ["LogoSwitch"]
        ),
        .testTarget(
            name: "LogosAccountsTests",
            dependencies: ["LogosAccounts"]
        ),
        .testTarget(
            name: "LogosUsageTests",
            dependencies: ["LogosUsage", "LogosAccounts"]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos", "LogoSwitch"]
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
