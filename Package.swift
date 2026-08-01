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
        .library(name: "LogoSwitch", targets: ["LogoSwitch"])
        // #92: the standalone MultiStats viewer target was retired — the in-app
        // 帳號用量 window (AccountUsageWindow over LogosUsage) is its superset. Its
        // source is preserved under archive/logos-multistats-target/.
    ],
    dependencies: [
        .package(url: "https://github.com/PsychQuant/SwiftTerm.git", branch: "logos-renderer-base"),
        // #107: our fork — upstream's Bundle.module access fatalErrors (killing
        // the app) when the resource bundle isn't at SwiftPM's two hardcoded
        // candidates; the logos-base branch probes Contents/Resources etc. and
        // fails soft (init returns nil -> CodeViewer's plain-text fallback).
        .package(url: "https://github.com/PsychQuant/Highlightr.git", branch: "logos-base"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        // merge-multistats-into-logos — credential-free account registry layer:
        // account model, config-dir convention, filesystem discovery, config-JSON
        // identity parsing. Foundation-only; covered by the red-line audit scan.
        .target(name: "LogosAccounts"),

        // Per-account inference gateway (spec 2026-07-31): refcounted pool of
        // supervised proxy child processes, one per active isolated account.
        // Foundation + os only; handles no credentials, so it never imports
        // Security (same red line as LogoSwitch).
        .target(name: "LogosGateway", dependencies: ["LogosAccounts"]),

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
                "LogosGateway",
                "LogosUsage",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Yams", package: "Yams")
            ]
        ),

        .testTarget(
            name: "LogoSwitchTests",
            dependencies: [
                "LogoSwitch",
                "LogosAccounts",
                // #66: RedLineAuditTests parses project.yml STRUCTURALLY (Yams
                // resolves anchors/aliases/merge keys at load) to close the
                // duplicate-key and alias bypasses of the old line-heuristic
                // red-line scan of the LogoSwitch XcodeGen target.
                .product(name: "Yams", package: "Yams")
            ]
        ),
        .testTarget(
            name: "LogosAccountsTests",
            dependencies: ["LogosAccounts"]
        ),
        .testTarget(
            name: "LogosGatewayTests",
            dependencies: ["LogosGateway", "LogosAccounts"]
        ),
        .testTarget(
            name: "LogosUsageTests",
            dependencies: ["LogosUsage", "LogosAccounts"]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos", "LogoSwitch"]
        ),
        // #65 — build-graph drift guard. Asserts every Package.swift library
        // target is mirrored in project.yml (the XcodeGen source for Track B), so
        // a future module extraction that forgets project.yml fails LOUD in the
        // plain `swift test` hard gate instead of silently breaking Track B (the
        // #39 / #60 recurrence). Yams (already a package dep) parses project.yml's
        // targets: mapping structurally (also used by LogoSwitchTests' #66 red-line
        // guard).
        .testTarget(
            name: "BuildGraphDriftTests",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ]
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
