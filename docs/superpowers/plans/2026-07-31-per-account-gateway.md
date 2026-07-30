# Per-Account Inference Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every isolated Logos account its own inference-gateway process — distinct port, distinct state directory, distinct upstream — so one account's rate limit can never throttle another.

**Architecture:** A new `LogosGateway` module owns a refcounted, lazy pool of supervised child processes keyed by account id. Logos runs a *configured command* (defaulting to an auto-detected `claude-hot-limit` proxy) and stays ignorant of the proxy's wire protocol. The pool hands back a `http://127.0.0.1:<port>` base URL that `ClaudeConfigEnvironment` injects as `ANTHROPIC_BASE_URL` at spawn. The system-default ("main") account is deliberately excluded and keeps its ambient global gateway.

**Tech Stack:** Swift 6, SwiftPM, swift-testing (`import Testing`), Foundation `Process`, POSIX sockets for port allocation and readiness probing, XcodeGen (`project.yml`) for Track B mirroring.

**Spec:** `docs/superpowers/specs/2026-07-31-per-account-gateway-design.md`

## Global Constraints

- **Swift 6, macOS 15+ minimum** (`Package.swift` declares `.macOS(.v15)`; `project.yml` declares `deploymentTarget.macOS: "15.0"`). Both must stay in sync.
- **New tests use swift-testing**, not XCTest: `import Testing`, `@Suite`, `@Test`, `#expect`. Match the existing style in `Tests/LogosTests/AdvancedSettingsTests.swift`.
- **No emoji in code or comments.**
- **Mark synchronous `@Test` functions `nonisolated`** when they touch statics on a `Scene`/`View` type. Such statics inherit `@MainActor`; a sync non-isolated test passes on a lenient local toolchain but fails on strict `macos-latest` CI. Actor-isolated async tests are unaffected.
- **Commit messages:** conventional commits (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`). If referencing an issue, put the number at the **end** in parentheses — `feat: add gateway pool (#N)`. Never write `fix: #N ...`; a number adjacent to the type auto-closes the issue on push.
- **Adding a `Package.swift` library target is a three-file change.** `Package.swift` + `project.yml` (`targets:`) + the expected-set assertion in `Tests/BuildGraphDriftTests`. Miss any one and `swift test` goes red or Track B silently breaks.
- **`LogoSwitch` must never import `Security`** (red line, enforced by `Tests/LogoSwitchTests/RedLineAuditTests.swift`). `LogosGateway` inherits the same rule by convention — it handles no credentials.
- **If `swift test` reports a suspiciously small test count, the build cache is corrupt.** Run `rm -rf .build` and re-run before believing a green result.
- Run the full gate with `swift test` (or `make tests`) at the end of every task.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Sources/LogosGateway/GatewayDescriptor.swift` | Value type: what to run for one account (argv, port, state dir, upstream) + derived `baseURL` and child `environment` |
| `Sources/LogosGateway/GatewayCommandResolver.swift` | Pure: locate the default proxy command by highest **semver** under the plugin cache |
| `Sources/LogosGateway/PortAllocator.swift` | Actor: hand out free loopback ports via bind-port-0 probing |
| `Sources/LogosGateway/GatewayProcess.swift` | Actor: one supervised child — spawn, TCP readiness, terminate, restart |
| `Sources/LogosGateway/GatewayPool.swift` | Actor: refcounted registry keyed by `account.id`; the only type that knows about refcounts |
| `Sources/LogosGateway/GatewayLog.swift` | `os.Logger` handles for the module |
| `Sources/LogoSwitch/ClaudeConfigEnvironment.swift` | **Modify:** inject or strip `ANTHROPIC_BASE_URL` |
| `Sources/LogoSwitch/ClaudeProcessConfig.swift` | **Modify:** accept and forward `gatewayBaseURL` |
| `Sources/LogoSwitch/AccountManager.swift` | **Modify:** shut the gateway down before the reaper deletes the dir |
| `Sources/LogosAccounts/Account.swift` | **Modify:** add optional `upstream` |
| `Sources/Logos/Models/AdvancedSettings.swift` | **Modify:** `gatewayEnabled` + `gatewayCommand` |
| `Sources/Logos/Views/MainArea/TerminalPaneView.swift` | **Modify:** async acquire in `.task(id:)`, banner on failure |
| `Sources/Logos/Views/MainArea/GatewayUnavailableBanner.swift` | New banner view for the failure policy |

---

### Task 1: Register the `LogosGateway` module

The build graph is described in three places that must agree. Doing this first — with an empty module — means every later task lands in a target that already compiles under both `swift test` and `xcodebuild`.

**Files:**
- Create: `Sources/LogosGateway/GatewayLog.swift`
- Modify: `Package.swift`
- Modify: `project.yml`
- Modify: `Tests/BuildGraphDriftTests/BuildGraphDriftTests.swift`
- Create: `Tests/LogosGatewayTests/GatewayModuleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `LogosGateway` module; `GatewayLog.pool`, `GatewayLog.process`, `GatewayLog.resolver` (`os.Logger`, subsystem `app.getlogos.logos`).

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/GatewayModuleTests.swift`:

```swift
import Testing
@testable import LogosGateway

@Suite struct GatewayModuleTests {

    /// The module exists and is importable. This is the scaffold's only claim;
    /// real behavior arrives in later tasks.
    @Test func moduleIsImportable() {
        #expect(GatewayLog.subsystem == "app.getlogos.logos")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayModuleTests`
Expected: FAIL — `no such module 'LogosGateway'`.

- [ ] **Step 3: Create the module source**

Create `Sources/LogosGateway/GatewayLog.swift`:

```swift
import Foundation
import os

/// Logging handles for the per-account gateway layer.
///
/// Shares the app-wide `app.getlogos.logos` subsystem so a single
/// `log show --predicate 'subsystem == "app.getlogos.logos"'` covers gateway
/// events alongside the rest of the app (the Track A smoke reads this trail).
public enum GatewayLog {

    public static let subsystem = "app.getlogos.logos"

    public static let pool = Logger(subsystem: subsystem, category: "gateway-pool")
    public static let process = Logger(subsystem: subsystem, category: "gateway-process")
    public static let resolver = Logger(subsystem: subsystem, category: "gateway-resolver")
}
```

- [ ] **Step 4: Register in `Package.swift`**

Add the library target after the `LogosAccounts` target declaration:

```swift
        // Per-account inference gateway (spec 2026-07-31): refcounted pool of
        // supervised proxy child processes, one per active isolated account.
        // Foundation + os only; handles no credentials, so it never imports
        // Security (same red line as LogoSwitch).
        .target(name: "LogosGateway"),
```

Add its test target alongside the other test targets:

```swift
        .testTarget(
            name: "LogosGatewayTests",
            dependencies: ["LogosGateway", "LogosAccounts"]
        ),
```

Add `"LogosGateway"` to the `Logos` executable target's `dependencies` array, and add it to the `LogoSwitch` target's dependencies is **NOT** needed — `ClaudeConfigEnvironment` takes a plain `URL?`, so LogoSwitch stays independent of the gateway module.

- [ ] **Step 5: Mirror in `project.yml`**

Add under `targets:`, immediately after the `LogosAccounts:` block, mirroring the framework recipe:

```yaml
  # LogosGateway — per-account inference gateway pool (spec 2026-07-31).
  # Foundation + os only; no module deps, and it must NOT link Security (it
  # handles no credentials). Mirrors the LogosAccounts framework recipe.
  LogosGateway:
    type: framework
    platform: macOS
    sources:
      - path: Sources/LogosGateway
    settings:
      base:
        PRODUCT_NAME: LogosGateway
        PRODUCT_BUNDLE_IDENTIFIER: app.getlogos.logosGateway
        GENERATE_INFOPLIST_FILE: "YES"
```

Then add `- target: LogosGateway` to the `Logos:` target's `dependencies:` list.

- [ ] **Step 6: Update the drift guard's expected set**

`Tests/BuildGraphDriftTests/BuildGraphDriftTests.swift` hard-codes the library set. Leaving it stale fails with a message that misleadingly blames `project.yml`. Change:

```swift
        #expect(
            Set(libraries) == ["LogosAccounts", "LogosUsage", "LogoSwitch"],
            "Package.swift library extraction drifted: got \(libraries.sorted())"
        )
```

to:

```swift
        #expect(
            Set(libraries) == ["LogosAccounts", "LogosGateway", "LogosUsage", "LogoSwitch"],
            "Package.swift library extraction drifted: got \(libraries.sorted())"
        )
```

- [ ] **Step 7: Run the full gate**

Run: `swift test`
Expected: PASS, including `GatewayModuleTests.moduleIsImportable` and `BuildGraphDriftTests.packageLibrariesAreAllMirroredInProjectYml`.

If the reported test count looks far smaller than usual, run `rm -rf .build && swift test` before trusting it.

- [ ] **Step 8: Commit**

```bash
git add Package.swift project.yml Sources/LogosGateway Tests/LogosGatewayTests Tests/BuildGraphDriftTests
git commit -m "feat: register LogosGateway module across the build graph"
```

---

### Task 2: `GatewayCommandResolver` — semver, not lexicographic

**Files:**
- Create: `Sources/LogosGateway/GatewayCommandResolver.swift`
- Create: `Tests/LogosGatewayTests/GatewayCommandResolverTests.swift`

**Interfaces:**
- Consumes: `GatewayLog` (Task 1).
- Produces:
  - `GatewayCommandResolver.highestVersion(in names: [String]) -> String?`
  - `GatewayCommandResolver.resolve(home: URL, fileManager: FileManager) -> [String]?` returning argv.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/GatewayCommandResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import LogosGateway

@Suite struct GatewayCommandResolverTests {

    /// The load-bearing case. Both versions exist on the maintainer's machine,
    /// and a lexicographic max picks "1.9.0" — silently running an older proxy.
    @Test func picksHighestSemverNotLexicographic() {
        #expect(GatewayCommandResolver.highestVersion(in: ["1.9.0", "1.19.0"]) == "1.19.0")
        #expect(GatewayCommandResolver.highestVersion(in: ["1.19.0", "1.9.0"]) == "1.19.0")
        #expect(GatewayCommandResolver.highestVersion(in: ["2.0.0", "10.0.0"]) == "10.0.0")
    }

    @Test func ignoresNonNumericDirectoryNames() {
        #expect(GatewayCommandResolver.highestVersion(in: [".DS_Store", "unknown", "1.2.3"]) == "1.2.3")
        #expect(GatewayCommandResolver.highestVersion(in: ["unknown"]) == nil)
        #expect(GatewayCommandResolver.highestVersion(in: []) == nil)
    }

    @Test func resolvesArgvWhenScriptExists() throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-resolve-\(UUID().uuidString)")
        let versionDir = home.appending(
            path: ".claude/plugins/cache/claude-hot-limit/claude-hot-limit/1.19.0/proxy"
        )
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let script = versionDir.appending(path: "rate-limit-proxy.py")
        try Data("print('x')".utf8).write(to: script)
        defer { try? FileManager.default.removeItem(at: home) }

        let argv = GatewayCommandResolver.resolve(home: home)
        #expect(argv == ["/usr/bin/env", "python3", script.path])
    }

    @Test func returnsNilWhenPluginAbsent() {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-absent-\(UUID().uuidString)")
        #expect(GatewayCommandResolver.resolve(home: home) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayCommandResolverTests`
Expected: FAIL — `cannot find 'GatewayCommandResolver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LogosGateway/GatewayCommandResolver.swift`:

```swift
import Foundation

/// Locates the default gateway command: the newest `claude-hot-limit`
/// rate-limit proxy installed in the Claude Code plugin cache.
///
/// Pure apart from the injected `FileManager`, so the version-ordering rule is
/// provable without touching the real plugin cache.
public enum GatewayCommandResolver {

    /// Directory holding one subdirectory per installed plugin version.
    public static func pluginVersionsRoot(home: URL) -> URL {
        home.appending(path: ".claude/plugins/cache/claude-hot-limit/claude-hot-limit")
    }

    /// Highest version among directory names, ordered NUMERICALLY per component.
    ///
    /// Lexicographic ordering is wrong here and not hypothetically so: the
    /// maintainer's machine holds both `1.9.0` and `1.19.0`, and a string `max()`
    /// picks `1.9.0` — quietly running a proxy several releases behind. Names
    /// that are not all-numeric dot-separated components are skipped.
    public static func highestVersion(in names: [String]) -> String? {
        names
            .compactMap { name -> (key: [Int], name: String)? in
                let parts = name.split(separator: ".", omittingEmptySubsequences: false)
                guard !parts.isEmpty else { return nil }
                var key: [Int] = []
                for part in parts {
                    guard let value = Int(part), value >= 0 else { return nil }
                    key.append(value)
                }
                return (key, name)
            }
            .max { $0.key.lexicographicallyPrecedes($1.key) }?
            .name
    }

    /// Full argv for the default gateway command, or nil when the plugin is not
    /// installed. `nil` means "no gateway configured" — the caller's failure
    /// policy decides what that implies for the account.
    public static func resolve(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String]? {
        let root = pluginVersionsRoot(home: home)
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            GatewayLog.resolver.notice("no claude-hot-limit plugin cache found")
            return nil
        }
        guard let version = highestVersion(in: names) else {
            GatewayLog.resolver.notice("plugin cache holds no numeric version dirs")
            return nil
        }
        let script = root.appending(path: "\(version)/proxy/rate-limit-proxy.py")
        guard fileManager.isReadableFile(atPath: script.path) else {
            GatewayLog.resolver.notice("proxy script missing for version \(version, privacy: .public)")
            return nil
        }
        GatewayLog.resolver.notice("resolved gateway command from version \(version, privacy: .public)")
        return ["/usr/bin/env", "python3", script.path]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GatewayCommandResolverTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogosGateway/GatewayCommandResolver.swift Tests/LogosGatewayTests/GatewayCommandResolverTests.swift
git commit -m "feat: resolve default gateway command by highest semver"
```

---

### Task 3: `PortAllocator`

**Files:**
- Create: `Sources/LogosGateway/PortAllocator.swift`
- Create: `Tests/LogosGatewayTests/PortAllocatorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `actor PortAllocator` with `init()`, `func allocate() throws -> UInt16`, `func release(_ port: UInt16)`
  - `enum PortAllocationError: Error, Equatable`

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/PortAllocatorTests.swift`:

```swift
import Foundation
import Testing
@testable import LogosGateway

@Suite struct PortAllocatorTests {

    @Test func allocatesAUsablePort() async throws {
        let allocator = PortAllocator()
        let port = try await allocator.allocate()
        #expect(port > 1024)
    }

    /// Two allocations must not collide within one process, even though the OS
    /// is free to hand back the same ephemeral port after the probe socket closes.
    @Test func allocatesDistinctPorts() async throws {
        let allocator = PortAllocator()
        let a = try await allocator.allocate()
        let b = try await allocator.allocate()
        #expect(a != b)
    }

    /// A released port becomes eligible again.
    @Test func releaseMakesPortReusable() async throws {
        let allocator = PortAllocator()
        let a = try await allocator.allocate()
        await allocator.release(a)
        let held = await allocator.heldPorts
        #expect(!held.contains(a))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PortAllocatorTests`
Expected: FAIL — `cannot find 'PortAllocator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LogosGateway/PortAllocator.swift`:

```swift
import Foundation

public enum PortAllocationError: Error, Equatable {
    case socketCreationFailed(code: Int32)
    case bindFailed(code: Int32)
    case getsocknameFailed(code: Int32)
    /// Every probe returned a port already handed out this process.
    case exhausted
}

/// Hands out free loopback ports for gateway children.
///
/// The proxy binds the port itself from `RATE_LIMIT_PROXY_PORT`, and its
/// readiness line prints the port it was *asked* for rather than the one it
/// bound — so `RATE_LIMIT_PROXY_PORT=0` would let the OS choose but leave the
/// choice unrecoverable. Logos therefore picks a concrete port up front by
/// binding `127.0.0.1:0`, reading the assignment back, and closing.
///
/// Closing before the child binds leaves a small TOCTOU window. It is accepted
/// rather than engineered away: the caller retries on bind failure, and holding
/// the socket open would prevent the child from binding at all.
public actor PortAllocator {

    private var handedOut: Set<UInt16> = []

    public init() {}

    /// Ports currently considered in use. Exposed for tests.
    public var heldPorts: Set<UInt16> { handedOut }

    public func allocate(maxAttempts: Int = 16) throws -> UInt16 {
        for _ in 0..<maxAttempts {
            let port = try Self.probeFreePort()
            if !handedOut.contains(port) {
                handedOut.insert(port)
                return port
            }
        }
        throw PortAllocationError.exhausted
    }

    public func release(_ port: UInt16) {
        handedOut.remove(port)
    }

    /// Bind `127.0.0.1:0`, read back the OS-assigned port, close.
    static func probeFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PortAllocationError.socketCreationFailed(code: errno) }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                          // 0 asks the OS to assign
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw PortAllocationError.bindFailed(code: errno) }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                getsockname(fd, generic, &length)
            }
        }
        guard nameResult == 0 else { throw PortAllocationError.getsocknameFailed(code: errno) }

        return UInt16(bigEndian: bound.sin_port)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PortAllocatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogosGateway/PortAllocator.swift Tests/LogosGatewayTests/PortAllocatorTests.swift
git commit -m "feat: allocate free loopback ports for gateway children"
```

---

### Task 4: `GatewayDescriptor`

**Files:**
- Create: `Sources/LogosGateway/GatewayDescriptor.swift`
- Create: `Tests/LogosGatewayTests/GatewayDescriptorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `struct GatewayDescriptor: Sendable, Equatable` with stored `accountID: String`, `command: [String]`, `port: UInt16`, `stateDirectory: String`, `upstream: URL`; derived `baseURL: URL` and `environment: [String: String]`; static `defaultUpstream: URL`; static `stateDirectory(forAccountHome:) -> String`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/GatewayDescriptorTests.swift`:

```swift
import Foundation
import Testing
@testable import LogosGateway

@Suite struct GatewayDescriptorTests {

    private func makeDescriptor(port: UInt16 = 51234) -> GatewayDescriptor {
        GatewayDescriptor(
            accountID: "ACC-1",
            command: ["/usr/bin/env", "python3", "/tmp/proxy.py"],
            port: port,
            stateDirectory: "/tmp/acc-1/hot-limit",
            upstream: GatewayDescriptor.defaultUpstream
        )
    }

    @Test func baseURLTargetsLoopbackOnTheAssignedPort() {
        #expect(makeDescriptor(port: 51234).baseURL.absoluteString == "http://127.0.0.1:51234")
    }

    /// The three knobs the proxy already reads. Getting a name wrong here means
    /// the child silently falls back to its defaults — port 8787 and the SHARED
    /// state file — which is precisely the bug this feature exists to fix.
    @Test func environmentCarriesPortUpstreamAndStateDir() {
        let env = makeDescriptor().environment
        #expect(env["RATE_LIMIT_PROXY_PORT"] == "51234")
        #expect(env["RATE_LIMIT_PROXY_UPSTREAM"] == "https://api.anthropic.com")
        #expect(env["CLAUDE_HOT_LIMIT_DATA"] == "/tmp/acc-1/hot-limit")
    }

    /// State lives INSIDE the account dir so AccountReaper cleans it up with the
    /// account and needs no change of its own.
    @Test func stateDirectoryNestsInsideTheAccountHome() {
        let path = GatewayDescriptor.stateDirectory(forAccountHome: "/Users/x/.logos/accounts/ACC-1")
        #expect(path == "/Users/x/.logos/accounts/ACC-1/hot-limit")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayDescriptorTests`
Expected: FAIL — `cannot find 'GatewayDescriptor' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LogosGateway/GatewayDescriptor.swift`:

```swift
import Foundation

/// Everything needed to run one account's gateway.
///
/// A value type on purpose: the pool decides *what* to run, `GatewayProcess`
/// decides *how*, and neither needs to reach into the other.
public struct GatewayDescriptor: Sendable, Equatable {

    public let accountID: String
    /// Full argv. Never a shell string — nothing here is word-split by a shell,
    /// so a path containing spaces needs no quoting.
    public let command: [String]
    public let port: UInt16
    public let stateDirectory: String
    public let upstream: URL

    public init(
        accountID: String,
        command: [String],
        port: UInt16,
        stateDirectory: String,
        upstream: URL = GatewayDescriptor.defaultUpstream
    ) {
        self.accountID = accountID
        self.command = command
        self.port = port
        self.stateDirectory = stateDirectory
        self.upstream = upstream
    }

    public static let defaultUpstream = URL(string: "https://api.anthropic.com")!

    /// What the spawned claude gets as `ANTHROPIC_BASE_URL`.
    public var baseURL: URL {
        // Infallible: fixed scheme, literal IPv4 loopback, numeric port.
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The child's environment overlay — the three knobs the claude-hot-limit
    /// proxy already reads. Without them it would fall back to port 8787 and the
    /// shared `~/.cache/claude-hot-limit/rate-state.jsonl`, re-joining every
    /// other account in one rate-limit bucket.
    public var environment: [String: String] {
        [
            "RATE_LIMIT_PROXY_PORT": String(port),
            "RATE_LIMIT_PROXY_UPSTREAM": upstream.absoluteString,
            "CLAUDE_HOT_LIMIT_DATA": stateDirectory
        ]
    }

    /// Per-account proxy state, nested inside the account's own directory so
    /// `AccountReaper`'s existing whole-directory removal cleans it up too.
    public static func stateDirectory(forAccountHome home: String) -> String {
        "\(home)/hot-limit"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GatewayDescriptorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LogosGateway/GatewayDescriptor.swift Tests/LogosGatewayTests/GatewayDescriptorTests.swift
git commit -m "feat: add GatewayDescriptor with per-account proxy environment"
```

---

### Task 5: `ClaudeConfigEnvironment` injects and strips `ANTHROPIC_BASE_URL`

**Files:**
- Modify: `Sources/LogoSwitch/ClaudeConfigEnvironment.swift`
- Modify: `Tests/LogoSwitchTests/ClaudeConfigEnvironmentTests.swift` (add cases; create the file if it does not exist)

**Interfaces:**
- Consumes: nothing (takes a plain `URL?`, so LogoSwitch stays independent of `LogosGateway`).
- Produces: `ClaudeConfigEnvironment.apply(base:configDir:gatewayBaseURL:)` — third parameter defaults to `nil`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LogoSwitchTests/ClaudeConfigEnvironmentTests.swift` (create with the imports below if absent):

```swift
import Foundation
import Testing
@testable import LogoSwitch

@Suite struct ClaudeConfigEnvironmentGatewayTests {

    @Test func injectsGatewayBaseURLWhenGiven() {
        let env = ClaudeConfigEnvironment.apply(
            base: [:],
            configDir: "/tmp/acc/.claude",
            gatewayBaseURL: URL(string: "http://127.0.0.1:51234")!
        )
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:51234")
    }

    /// The mirror of the #54 stale-CLAUDE_CONFIG_DIR strip. Without it, launching
    /// Logos from a shell that exports ANTHROPIC_BASE_URL makes every account
    /// silently inherit one shared gateway — the exact bug this feature fixes,
    /// re-entering through the back door.
    @Test func stripsInheritedBaseURLWhenNoGateway() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"],
            configDir: "/tmp/acc/.claude",
            gatewayBaseURL: nil
        )
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
    }

    /// Omitting the argument must behave exactly like passing nil, so no existing
    /// call site accidentally leaks an inherited value.
    @Test func defaultArgumentAlsoStrips() {
        let env = ClaudeConfigEnvironment.apply(
            base: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8787"],
            configDir: nil
        )
        #expect(env["ANTHROPIC_BASE_URL"] == nil)
    }

    /// The pre-existing config-dir contract is untouched.
    @Test func configDirBehaviorUnchanged() {
        let isolated = ClaudeConfigEnvironment.apply(base: [:], configDir: "/tmp/acc/.claude")
        #expect(isolated["CLAUDE_CONFIG_DIR"] == "/tmp/acc/.claude")
        #expect(isolated["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == "/tmp/acc/.claude")

        let systemDefault = ClaudeConfigEnvironment.apply(
            base: ["CLAUDE_CONFIG_DIR": "/stale", "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/stale"],
            configDir: nil
        )
        #expect(systemDefault["CLAUDE_CONFIG_DIR"] == nil)
        #expect(systemDefault["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeConfigEnvironmentGatewayTests`
Expected: FAIL — extra argument `gatewayBaseURL` in call.

- [ ] **Step 3: Write the implementation**

In `Sources/LogoSwitch/ClaudeConfigEnvironment.swift`, change the signature and add the injection block before `return env`:

```swift
    public static func apply(
        base: [String: String],
        configDir: String?,
        gatewayBaseURL: URL? = nil
    ) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"

        if let configDir {
            env["CLAUDE_CONFIG_DIR"] = configDir
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = configDir
        } else {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
            env.removeValue(forKey: "CLAUDE_SECURESTORAGE_CONFIG_DIR")
        }

        // Transport-layer routing (spec 2026-07-31). Symmetric with the config-dir
        // strip above and for the same reason: an inherited ANTHROPIC_BASE_URL from
        // the login-shell env would silently pin this account to somebody else's
        // gateway. Note this only governs the PROCESS env — a settings.json `env`
        // entry outranks it (Claude Code writes settings `env` over the inherited
        // value at startup), which is exactly why the system-default account keeps
        // its ambient gateway and is excluded from the pool.
        if let gatewayBaseURL {
            env["ANTHROPIC_BASE_URL"] = gatewayBaseURL.absoluteString
        } else {
            env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        }

        return env
    }
```

Also extend the doc comment above the function with a bullet describing the new parameter.

- [ ] **Step 4: Run the full gate**

Run: `swift test`
Expected: PASS. If any pre-existing `ClaudeProcessConfigTests` case asserted that an inherited `ANTHROPIC_BASE_URL` survives, it will now fail — that is the intended behavior change; update the assertion to expect the strip.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogoSwitch/ClaudeConfigEnvironment.swift Tests/LogoSwitchTests
git commit -m "feat: inject or strip ANTHROPIC_BASE_URL in the account env transform"
```

---

### Task 6: `GatewayProcess` — spawn, TCP readiness, terminate, supervise

**Files:**
- Create: `Sources/LogosGateway/GatewayProcess.swift`
- Create: `Tests/LogosGatewayTests/GatewayProcessTests.swift`

**Interfaces:**
- Consumes: `GatewayDescriptor` (Task 4), `GatewayLog` (Task 1).
- Produces:
  - `actor GatewayProcess` with `init(descriptor: GatewayDescriptor)`, `func start(readinessTimeout: Duration) async throws`, `func terminate() async`, `var isRunning: Bool`
  - `enum GatewayProcessError: Error, Equatable { case launchFailed(String), readinessTimedOut(port: UInt16) }`

Readiness is a **TCP connect probe**, not stdout parsing. The command is user-configurable, so depending on `claude-hot-limit`'s specific readiness line would break the moment someone points `gatewayCommand` at a different proxy. "Something accepts connections on the port we assigned" is the only implementation-independent signal.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/GatewayProcessTests.swift`:

```swift
import Foundation
import Testing
@testable import LogosGateway

@Suite struct GatewayProcessTests {

    /// A stand-in gateway: listens on the assigned port so the readiness probe
    /// can succeed, without needing Python or the real proxy installed.
    private func fakeGatewayDescriptor(port: UInt16) -> GatewayDescriptor {
        let script = """
        import socket, os, time
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", int(os.environ["RATE_LIMIT_PROXY_PORT"])))
        s.listen(5)
        time.sleep(60)
        """
        return GatewayDescriptor(
            accountID: "ACC-FAKE",
            command: ["/usr/bin/env", "python3", "-c", script],
            port: port,
            stateDirectory: NSTemporaryDirectory(),
            upstream: GatewayDescriptor.defaultUpstream
        )
    }

    @Test func startsAndBecomesReady() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(descriptor: fakeGatewayDescriptor(port: port))
        try await process.start(readinessTimeout: .seconds(15))
        #expect(await process.isRunning)
        await process.terminate()
    }

    @Test func terminateStopsTheChild() async throws {
        let port = try await PortAllocator().allocate()
        let process = GatewayProcess(descriptor: fakeGatewayDescriptor(port: port))
        try await process.start(readinessTimeout: .seconds(15))
        await process.terminate()
        #expect(await process.isRunning == false)
    }

    /// A command that exits immediately never binds, so readiness must time out
    /// rather than hang or falsely report success.
    @Test func timesOutWhenNothingEverBinds() async throws {
        let port = try await PortAllocator().allocate()
        let descriptor = GatewayDescriptor(
            accountID: "ACC-DEAD",
            command: ["/usr/bin/true"],
            port: port,
            stateDirectory: NSTemporaryDirectory()
        )
        let process = GatewayProcess(descriptor: descriptor)
        await #expect(throws: GatewayProcessError.self) {
            try await process.start(readinessTimeout: .milliseconds(800))
        }
        await process.terminate()
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayProcessTests`
Expected: FAIL — `cannot find 'GatewayProcess' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/LogosGateway/GatewayProcess.swift`:

```swift
import Foundation

public enum GatewayProcessError: Error, Equatable {
    case launchFailed(String)
    case readinessTimedOut(port: UInt16)
}

/// One supervised gateway child.
///
/// Readiness is a TCP connect probe against the assigned port, deliberately NOT
/// a parse of the child's stdout: the command is user-configurable, so any
/// dependence on one proxy's log format would break the moment it is pointed at
/// a different implementation. "Something is accepting connections on the port
/// we assigned" is the only implementation-independent readiness signal.
public actor GatewayProcess {

    public let descriptor: GatewayDescriptor
    private var process: Process?

    public init(descriptor: GatewayDescriptor) {
        self.descriptor = descriptor
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start(readinessTimeout: Duration = .seconds(10)) async throws {
        guard !isRunning else { return }

        try? FileManager.default.createDirectory(
            atPath: descriptor.stateDirectory,
            withIntermediateDirectories: true
        )

        guard let executable = descriptor.command.first else {
            throw GatewayProcessError.launchFailed("empty command")
        }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = Array(descriptor.command.dropFirst())
        child.environment = ProcessInfo.processInfo.environment.merging(
            descriptor.environment
        ) { _, overlay in overlay }
        // The child's own output is noise in the app log; the readiness probe and
        // exit status carry everything the pool acts on.
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice

        do {
            try child.run()
        } catch {
            throw GatewayProcessError.launchFailed(error.localizedDescription)
        }
        process = child

        GatewayLog.process.notice(
            "gateway spawned — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
        )

        try await waitUntilReady(timeout: readinessTimeout)
    }

    private func waitUntilReady(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Self.canConnect(port: descriptor.port) {
                GatewayLog.process.notice(
                    "gateway ready — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
                )
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        GatewayLog.process.error(
            "gateway readiness timed out — account=\(self.descriptor.accountID, privacy: .public) port=\(self.descriptor.port, privacy: .public)"
        )
        throw GatewayProcessError.readinessTimedOut(port: descriptor.port)
    }

    public func terminate(grace: Duration = .seconds(3)) async {
        guard let child = process, child.isRunning else {
            process = nil
            return
        }
        child.terminate()   // SIGTERM

        let deadline = ContinuousClock.now.advanced(by: grace)
        while child.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
        }
        process = nil
        GatewayLog.process.notice(
            "gateway terminated — account=\(self.descriptor.accountID, privacy: .public)"
        )
    }

    /// Single TCP connect attempt against the loopback port.
    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                connect(fd, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GatewayProcessTests`
Expected: PASS (3 tests). These spawn real short-lived children, so they take a few seconds.

- [ ] **Step 5: Write the failing crash-supervision test**

A gateway that dies mid-session must come back, or every request from that account fails
until the window is reopened. Append to `Tests/LogosGatewayTests/GatewayProcessTests.swift`:

```swift
@Suite struct GatewaySupervisionTests {

    /// A child that exits on its own must be relaunched.
    @Test func restartsAfterAnUnexpectedExit() async throws {
        let port = try await PortAllocator().allocate()
        // Binds, serves nothing, then exits after 1s — simulating a crash.
        let script = """
        import socket, os, time
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", int(os.environ["RATE_LIMIT_PROXY_PORT"])))
        s.listen(5)
        time.sleep(1)
        """
        let descriptor = GatewayDescriptor(
            accountID: "ACC-CRASH",
            command: ["/usr/bin/env", "python3", "-c", script],
            port: port,
            stateDirectory: NSTemporaryDirectory()
        )
        let process = GatewayProcess(descriptor: descriptor)
        try await process.start(readinessTimeout: .seconds(15))

        let first = await process.launchCount
        #expect(first == 1)

        // Wait past the child's self-exit plus the first backoff step.
        try await Task.sleep(for: .seconds(4))
        #expect(await process.launchCount > 1, "crashed gateway was never restarted")

        await process.terminate()
    }

    /// An intentional terminate() must NOT trigger the restart path.
    @Test func doesNotRestartAfterDeliberateTermination() async throws {
        let port = try await PortAllocator().allocate()
        let script = """
        import socket, os, time
        s = socket.socket()
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("127.0.0.1", int(os.environ["RATE_LIMIT_PROXY_PORT"])))
        s.listen(5)
        time.sleep(60)
        """
        let descriptor = GatewayDescriptor(
            accountID: "ACC-CLEAN",
            command: ["/usr/bin/env", "python3", "-c", script],
            port: port,
            stateDirectory: NSTemporaryDirectory()
        )
        let process = GatewayProcess(descriptor: descriptor)
        try await process.start(readinessTimeout: .seconds(15))
        await process.terminate()

        try await Task.sleep(for: .seconds(2))
        #expect(await process.launchCount == 1)
        #expect(await process.isRunning == false)
    }
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter GatewaySupervisionTests`
Expected: FAIL — no `launchCount` member; no restart occurs.

- [ ] **Step 7: Add supervision to `GatewayProcess`**

Add state and a bounded-backoff restart to `Sources/LogosGateway/GatewayProcess.swift`:

```swift
    /// How many times a child has been launched. Exposed so supervision is
    /// observable without reaching into `Process`.
    public private(set) var launchCount = 0
    /// Set by `terminate()` so a deliberate stop is not mistaken for a crash.
    private var stopping = false
    private var restartAttempt = 0

    /// Backoff schedule for crash restarts. Bounded: after the last step the
    /// gateway stays down and the caller's failure policy takes over.
    private static let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]
```

In `start(...)`, immediately after `process = child`, add `launchCount += 1` and install the
termination handler. `Process.terminationHandler` fires on an arbitrary thread, so it may only
hop back into the actor:

```swift
        launchCount += 1
        restartAttempt = 0
        child.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.handleUnexpectedExit() }
        }
```

Add the handler and reset `stopping` in `terminate()`:

```swift
    private func handleUnexpectedExit() async {
        guard !stopping else { return }
        guard restartAttempt < Self.backoff.count else {
            GatewayLog.process.error(
                "gateway restart budget exhausted — account=\(self.descriptor.accountID, privacy: .public)"
            )
            process = nil
            return
        }
        let delay = Self.backoff[restartAttempt]
        restartAttempt += 1
        GatewayLog.process.notice(
            "gateway exited unexpectedly, restarting — account=\(self.descriptor.accountID, privacy: .public) attempt=\(self.restartAttempt, privacy: .public)"
        )
        try? await Task.sleep(for: delay)
        guard !stopping else { return }
        process = nil
        // Preserve restartAttempt across the relaunch so the budget is bounded
        // overall, not reset by each successful start.
        let attempt = restartAttempt
        try? await start()
        restartAttempt = attempt
    }
```

In `terminate(grace:)`, set the flag first so the handler stands down, and clear it at the end:

```swift
    public func terminate(grace: Duration = .seconds(3)) async {
        stopping = true
        defer { stopping = false }
        guard let child = process, child.isRunning else {
            process = nil
            return
        }
        child.terminationHandler = nil
        child.terminate()
        // ... unchanged remainder ...
    }
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `swift test --filter GatewayProcessTests` then `swift test --filter GatewaySupervisionTests`
Expected: PASS (5 tests total). The supervision tests sleep for several seconds by design.

- [ ] **Step 9: Commit**

```bash
git add Sources/LogosGateway/GatewayProcess.swift Tests/LogosGatewayTests/GatewayProcessTests.swift
git commit -m "feat: supervise gateway children with TCP readiness and bounded-backoff restart"
```

---

### Task 7: `GatewayPool` — refcounting and the main-account exclusion

**Files:**
- Create: `Sources/LogosGateway/GatewayPool.swift`
- Create: `Tests/LogosGatewayTests/GatewayPoolTests.swift`
- Modify: `Package.swift` (add `LogosAccounts` to the `LogosGateway` target's dependencies)
- Modify: `project.yml` (add `- target: LogosAccounts` to the `LogosGateway` target)

**Interfaces:**
- Consumes: `GatewayDescriptor` (Task 4), `GatewayProcess` (Task 6), `PortAllocator` (Task 3), `GatewayCommandResolver` (Task 2), `Account` from `LogosAccounts`.
- Produces:
  - `actor GatewayPool` with `init(allocator:lingerSeconds:launch:)`
  - `func acquire(account: Account, command: [String]?, upstream: URL?) async throws -> URL?`
  - `func release(accountID: String) async`
  - `func shutdown(accountID: String) async`
  - `var activeAccountIDs: Set<String>`

The `launch` closure is the seam that lets tests exercise refcount semantics without spawning real processes.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosGatewayTests/GatewayPoolTests.swift`:

```swift
import Foundation
import Testing
import LogosAccounts
@testable import LogosGateway

/// Counts launches and terminations without spawning anything.
private actor StubLauncher {
    private(set) var launched: [String] = []
    private(set) var terminated: [String] = []

    func launch(_ descriptor: GatewayDescriptor) async throws {
        launched.append(descriptor.accountID)
    }

    func terminate(_ accountID: String) async {
        terminated.append(accountID)
    }
}

@Suite struct GatewayPoolTests {

    private func isolatedAccount(id: String = "ACC-1") -> Account {
        Account(id: id, label: "Work", isSystemDefault: false)
    }

    private func makePool(stub: StubLauncher, linger: Duration = .zero) -> GatewayPool {
        GatewayPool(
            allocator: PortAllocator(),
            linger: linger,
            launch: { descriptor in try await stub.launch(descriptor) },
            terminate: { accountID in await stub.terminate(accountID) }
        )
    }

    /// The system-default account is excluded by design: its settings come from
    /// the user's global ~/.claude/settings.json, whose `env` block outranks any
    /// process env Logos injects, and #54 forbids Logos writing there.
    @Test func systemDefaultAccountGetsNoGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let main = Account(id: Account.systemDefaultID, label: "Main", isSystemDefault: true)

        let url = try await pool.acquire(account: main, command: ["/usr/bin/true"], upstream: nil)

        #expect(url == nil)
        #expect(await stub.launched.isEmpty)
    }

    @Test func twoAcquiresShareOneGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        let first = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)
        let second = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)

        #expect(first != nil)
        #expect(first == second)
        #expect(await stub.launched == ["ACC-1"])
    }

    @Test func gatewaySurvivesUntilTheLastRelease() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        _ = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)
        _ = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)

        await pool.release(accountID: "ACC-1")
        #expect(await stub.terminated.isEmpty)
        #expect(await pool.activeAccountIDs.contains("ACC-1"))

        await pool.release(accountID: "ACC-1")
        #expect(await stub.terminated == ["ACC-1"])
        #expect(await pool.activeAccountIDs.isEmpty)
    }

    /// Two accounts must never share a port — the whole point of the feature.
    @Test func distinctAccountsGetDistinctPorts() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)

        let a = try await pool.acquire(account: isolatedAccount(id: "ACC-A"), command: ["/usr/bin/true"], upstream: nil)
        let b = try await pool.acquire(account: isolatedAccount(id: "ACC-B"), command: ["/usr/bin/true"], upstream: nil)

        #expect(a != nil)
        #expect(b != nil)
        #expect(a != b)
    }

    /// shutdown ignores the refcount — it is the account-removal path, and must
    /// stop the child BEFORE AccountReaper deletes its working directory.
    @Test func shutdownTerminatesRegardlessOfRefcount() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)
        let account = isolatedAccount()

        _ = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)
        _ = try await pool.acquire(account: account, command: ["/usr/bin/true"], upstream: nil)

        await pool.shutdown(accountID: "ACC-1")

        #expect(await stub.terminated == ["ACC-1"])
        #expect(await pool.activeAccountIDs.isEmpty)
    }

    /// A nil command means no gateway is configured; the caller's failure policy
    /// decides what that means for the account.
    @Test func nilCommandYieldsNoGateway() async throws {
        let stub = StubLauncher()
        let pool = makePool(stub: stub)

        let url = try await pool.acquire(account: isolatedAccount(), command: nil, upstream: nil)

        #expect(url == nil)
        #expect(await stub.launched.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayPoolTests`
Expected: FAIL — `cannot find 'GatewayPool' in scope`.

- [ ] **Step 3: Add the `LogosAccounts` dependency**

In `Package.swift`, change the gateway target to:

```swift
        .target(name: "LogosGateway", dependencies: ["LogosAccounts"]),
```

In `project.yml`, add to the `LogosGateway:` target block, between `sources:` and `settings:`:

```yaml
    dependencies:
      - target: LogosAccounts
```

- [ ] **Step 4: Write the implementation**

Create `Sources/LogosGateway/GatewayPool.swift`:

```swift
import Foundation
import LogosAccounts

/// Refcounted, lazy pool of per-account gateways.
///
/// Granularity is per ACCOUNT, not per window: two windows on the same account
/// genuinely spend the same quota, so they should share one rate-limit bucket.
/// And not per registered account either — a machine with dozens of accounts
/// runs a gateway only for the few actually in use.
public actor GatewayPool {

    private struct Entry {
        var refcount: Int
        var baseURL: URL
        var port: UInt16
        var lingerTask: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]
    private let allocator: PortAllocator
    private let linger: Duration
    private let launch: @Sendable (GatewayDescriptor) async throws -> Void
    private let terminate: @Sendable (String) async -> Void

    /// - Parameters:
    ///   - linger: how long a gateway stays alive after its refcount hits zero,
    ///     so an account switch or window reopen reuses it instead of paying
    ///     spawn plus readiness again. Tests pass `.zero` for determinism.
    ///   - launch/terminate: injected so refcount semantics are provable without
    ///     spawning real children.
    public init(
        allocator: PortAllocator = PortAllocator(),
        linger: Duration = .seconds(5),
        launch: (@Sendable (GatewayDescriptor) async throws -> Void)? = nil,
        terminate: (@Sendable (String) async -> Void)? = nil
    ) {
        self.allocator = allocator
        self.linger = linger
        self.launch = launch ?? { descriptor in
            let process = GatewayProcess(descriptor: descriptor)
            try await process.start()
            await GatewayProcessRegistry.shared.store(process, for: descriptor.accountID)
        }
        self.terminate = terminate ?? { accountID in
            await GatewayProcessRegistry.shared.terminate(accountID)
        }
    }

    public var activeAccountIDs: Set<String> { Set(entries.keys) }

    /// Ensure `account` has a running gateway and return its base URL.
    ///
    /// Returns nil — meaning "no gateway, spawn claude direct" — for the
    /// system-default account, and when no command is configured.
    public func acquire(
        account: Account,
        command: [String]?,
        upstream: URL?
    ) async throws -> URL? {
        guard !account.isSystemDefault else {
            GatewayLog.pool.notice("system-default account excluded from gateway pool")
            return nil
        }
        guard let command, !command.isEmpty else {
            GatewayLog.pool.notice("no gateway command configured")
            return nil
        }

        if var existing = entries[account.id] {
            existing.lingerTask?.cancel()
            existing.lingerTask = nil
            existing.refcount += 1
            entries[account.id] = existing
            return existing.baseURL
        }

        let port = try await allocator.allocate()
        let descriptor = GatewayDescriptor(
            accountID: account.id,
            command: command,
            port: port,
            stateDirectory: GatewayDescriptor.stateDirectory(forAccountHome: account.homeDirectoryPath),
            upstream: upstream ?? GatewayDescriptor.defaultUpstream
        )

        do {
            try await launch(descriptor)
        } catch {
            await allocator.release(port)
            throw error
        }

        entries[account.id] = Entry(refcount: 1, baseURL: descriptor.baseURL, port: port, lingerTask: nil)
        GatewayLog.pool.notice(
            "gateway acquired — account=\(account.id, privacy: .public) port=\(port, privacy: .public)"
        )
        return descriptor.baseURL
    }

    /// Drop one reference. At zero the gateway lingers briefly before teardown.
    public func release(accountID: String) async {
        guard var entry = entries[accountID] else { return }
        entry.refcount -= 1
        guard entry.refcount <= 0 else {
            entries[accountID] = entry
            return
        }

        if linger == .zero {
            entries[accountID] = entry
            await tearDown(accountID: accountID)
            return
        }

        entry.lingerTask = Task { [linger] in
            try? await Task.sleep(for: linger)
            guard !Task.isCancelled else { return }
            await self.tearDown(accountID: accountID)
        }
        entries[accountID] = entry
    }

    /// Stop an account's gateway regardless of refcount. Used on account removal,
    /// where the child must die BEFORE AccountReaper deletes its state directory.
    public func shutdown(accountID: String) async {
        entries[accountID]?.lingerTask?.cancel()
        await tearDown(accountID: accountID)
    }

    /// Stop every gateway. Called at app exit so no child is orphaned.
    public func shutdownAll() async {
        for accountID in entries.keys {
            entries[accountID]?.lingerTask?.cancel()
            await tearDown(accountID: accountID)
        }
    }

    private func tearDown(accountID: String) async {
        guard let entry = entries.removeValue(forKey: accountID) else { return }
        await terminate(accountID)
        await allocator.release(entry.port)
        GatewayLog.pool.notice("gateway torn down — account=\(accountID, privacy: .public)")
    }
}

/// Holds the live `GatewayProcess` objects for the pool's default (non-injected)
/// launch path. Kept separate so `GatewayPool` stores only value data and stays
/// trivially testable through the injected closures.
actor GatewayProcessRegistry {

    static let shared = GatewayProcessRegistry()

    private var processes: [String: GatewayProcess] = [:]

    func store(_ process: GatewayProcess, for accountID: String) {
        processes[accountID] = process
    }

    func terminate(_ accountID: String) async {
        guard let process = processes.removeValue(forKey: accountID) else { return }
        await process.terminate()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter GatewayPoolTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Run the full gate**

Run: `swift test`
Expected: PASS, including `BuildGraphDriftTests` (the `LogosGateway` dependency edit must not have broken the mirror).

- [ ] **Step 7: Commit**

```bash
git add Package.swift project.yml Sources/LogosGateway/GatewayPool.swift Tests/LogosGatewayTests/GatewayPoolTests.swift
git commit -m "feat: add refcounted per-account gateway pool"
```

---

### Task 8: Persisted configuration — `Account.upstream` and `AdvancedSettings`

**Files:**
- Modify: `Sources/LogosAccounts/Account.swift`
- Modify: `Sources/Logos/Models/AdvancedSettings.swift`
- Modify: `Tests/LogosAccountsTests/AccountTests.swift` (add cases)
- Modify: `Tests/LogosTests/AdvancedSettingsTests.swift` (add cases)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `Account.upstream: String?` (stored, `Codable`, defaults to nil)
  - `AdvancedSettings.gatewayEnabled: Bool` (default `true`)
  - `AdvancedSettings.gatewayCommand: [String]?` (default `nil` meaning auto-detect)

- [ ] **Step 1: Write the failing test**

Append to `Tests/LogosAccountsTests/AccountTests.swift`:

```swift
@Suite struct AccountUpstreamTests {

    @Test func upstreamDefaultsToNil() {
        #expect(Account(label: "Work").upstream == nil)
    }

    /// An index.json written before this field existed must still decode. A
    /// non-optional property here would throw and drop the ENTIRE registry —
    /// the same failure mode `isSystemDefault` was made optional to avoid.
    @Test func decodesLegacyAccountWithoutUpstream() throws {
        let legacy = """
        {"id":"ACC-1","label":"Work","createdAt":0,"isSystemDefault":false}
        """
        let decoder = JSONDecoder()
        let account = try decoder.decode(Account.self, from: Data(legacy.utf8))
        #expect(account.upstream == nil)
        #expect(account.id == "ACC-1")
    }

    @Test func roundTripsUpstream() throws {
        let account = Account(label: "Work", upstream: "https://gateway.example.com")
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded.upstream == "https://gateway.example.com")
    }
}
```

Append to `Tests/LogosTests/AdvancedSettingsTests.swift`, **inside** the existing
`@Suite("AdvancedSettings", .serialized) @MainActor struct AdvancedSettingsTests` (it already has
the private `tempDir() -> String` helper these use):

```swift
    @Test("gateway defaults")
    func gatewayDefaults() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        #expect(s.gatewayEnabled == true)
        #expect(s.gatewayCommand == nil)
    }

    @Test("gateway command persists as argv")
    func gatewayCommandPersists() {
        let dir = tempDir()
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = AdvancedSettings(persistence: p)
        // A path with a space proves argv storage: a shell-string field would
        // need quoting here and would word-split on read.
        s1.gatewayCommand = ["/usr/bin/env", "python3", "/tmp/my proxy.py"]

        let s2 = AdvancedSettings(persistence: p)
        #expect(s2.gatewayCommand == ["/usr/bin/env", "python3", "/tmp/my proxy.py"])
        #expect(s2.gatewayEnabled == true)
    }

    @Test("empty gateway command treated as nil")
    func emptyGatewayCommandAsNil() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        s.gatewayCommand = []
        #expect(s.gatewayCommand == nil)
        s.gatewayCommand = ["", ""]
        #expect(s.gatewayCommand == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountUpstreamTests` then `swift test --filter AdvancedSettings`
Expected: FAIL — no `upstream` / `gatewayEnabled` / `gatewayCommand` members.

- [ ] **Step 3: Add `Account.upstream`**

In `Sources/LogosAccounts/Account.swift`:

Add the stored property after `isSystemDefault`:

```swift
    /// Per-account gateway upstream (spec 2026-07-31). `nil` means the default
    /// `https://api.anthropic.com`. When set, the failure policy becomes
    /// FAIL-CLOSED: silently falling back to the default upstream would send
    /// traffic somewhere the operator did not direct it, which is a routing
    /// policy violation rather than a degradation.
    public let upstream: String?
```

Add the parameter to `init`, defaulted so no existing call site changes:

```swift
    public init(
        id: String = UUID().uuidString,
        label: String,
        createdAt: Date = Date(),
        isSystemDefault: Bool = false,
        upstream: String? = nil
    ) {
        self.id = id
        self.label = Account.byteBoundedLabel(label)
        self.createdAt = createdAt
        self.isSystemDefault = isSystemDefault
        self.upstream = upstream
    }
```

Add to `CodingKeys` and the custom decoder:

```swift
    enum CodingKeys: String, CodingKey {
        case id, label, createdAt, isSystemDefault, upstream
    }
```

```swift
        self.upstream = try c.decodeIfPresent(String.self, forKey: .upstream)
```

- [ ] **Step 4: Add the `AdvancedSettings` fields**

In `Sources/Logos/Models/AdvancedSettings.swift`, add two properties following the existing `_backing` + computed + `save()` pattern:

```swift
    @ObservationIgnored private var _gatewayEnabled: Bool = true
    /// Route isolated accounts through per-account gateways (spec 2026-07-31).
    /// Default ON. Turning it off makes every account spawn direct, which is the
    /// pre-feature behavior.
    public var gatewayEnabled: Bool {
        get { _gatewayEnabled }
        set {
            _gatewayEnabled = newValue
            save()
            Log.settings.notice("gatewayEnabled changed — enabled=\(newValue, privacy: .public)")
        }
    }

    @ObservationIgnored private var _gatewayCommand: [String]?
    /// Explicit gateway argv. `nil` auto-detects the newest claude-hot-limit
    /// proxy. Stored as argv rather than a shell string so nothing is ever
    /// word-split and a path containing spaces needs no quoting.
    public var gatewayCommand: [String]? {
        get { _gatewayCommand }
        set {
            let cleaned = newValue?.filter { !$0.isEmpty }
            _gatewayCommand = (cleaned?.isEmpty == false) ? cleaned : nil
            save()
            // Log only whether an override is set, never the argv (it contains paths).
            Log.settings.notice("gatewayCommand changed — set=\(self._gatewayCommand != nil, privacy: .public)")
        }
    }
```

Extend `save()` and `PersistedDTO`. Both new fields are optional in the DTO so a legacy `advanced.json` still decodes — a non-optional would fail the decode and reset ALL settings:

```swift
    private func save() {
        let dto = PersistedDTO(
            claudePathOverride: _claudePathOverride,
            logLevel: _logLevel,
            dangerouslySkipPermissions: _dangerouslySkipPermissions,
            gatewayEnabled: _gatewayEnabled,
            gatewayCommand: _gatewayCommand
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let claudePathOverride: String?
        let logLevel: LogLevel
        let dangerouslySkipPermissions: Bool?
        let gatewayEnabled: Bool?
        let gatewayCommand: [String]?
    }
```

And in `init`, restore them with defaults:

```swift
            _gatewayEnabled = dto.gatewayEnabled ?? true
            _gatewayCommand = dto.gatewayCommand
```

- [ ] **Step 5: Expose the toggle in Settings**

A persisted setting with no control is unreachable. Add a section to
`Sources/Logos/Views/Settings/AdvancedSettingsTab.swift`, after the existing `Section("Permissions")`
block, following that section's `Toggle` + `.accessibilityIdentifier` pattern:

```swift
            Section("Gateway") {
                Toggle(
                    "Route accounts through per-account gateways",
                    isOn: Binding(
                        get: { advanced.gatewayEnabled },
                        set: { advanced.gatewayEnabled = $0 }
                    )
                )
                .accessibilityIdentifier("logos.settings.gatewayToggle")

                Text(
                    """
                    Each account gets its own gateway process, so one account hitting a rate \
                    limit cannot throttle another. The main account is not included; it keeps \
                    whatever your global ~/.claude/settings.json specifies.

                    Routing through a gateway disables Remote Control and, unless \
                    ENABLE_TOOL_SEARCH is set, MCP tool search — both require a direct \
                    connection to api.anthropic.com.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
```

Match however this file already reaches `AdvancedSettings` (an `@Environment` or an `advanced`
property); do not introduce a second access path.

- [ ] **Step 6: Run the full gate**

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LogosAccounts/Account.swift Sources/Logos/Models/AdvancedSettings.swift Sources/Logos/Views/Settings/AdvancedSettingsTab.swift Tests/LogosAccountsTests Tests/LogosTests/AdvancedSettingsTests.swift
git commit -m "feat: persist per-account upstream and gateway settings"
```

---

### Task 9: Shut the gateway down before the reaper deletes its directory

**Files:**
- Modify: `Sources/LogoSwitch/AccountManager.swift`
- Modify: `Tests/LogoSwitchTests/AccountManagerTests.swift` (add a case)

**Interfaces:**
- Consumes: `GatewayPool.shutdown(accountID:)` (Task 7).
- Produces: `AccountManager.onAccountRemoved: (@Sendable (String) async -> Void)?` — an injected hook the app wires to the pool. A closure rather than a direct `GatewayPool` reference keeps `LogoSwitch` free of a `LogosGateway` dependency and keeps the ordering testable.

- [ ] **Step 1: Write the failing test**

Append to `Tests/LogoSwitchTests/AccountManagerTests.swift`:

`AccountReaper` is a struct with an injectable `home:`, and the existing `makeManager` helper in
this file does not pass one. Extend that helper (test file only) with a `reaper:` parameter
defaulting to today's behavior, then add the suite below.

Change the existing helper's signature and body to:

```swift
    private func makeManager(
        indexFileURL: URL? = nil,
        store: ActiveAccountStore = InMemoryActiveAccountStore(),
        ensureDirectory: @escaping (String) throws -> Void = { _ in },
        reaper: AccountReaper = AccountReaper()
    ) -> AccountManager {
        AccountManager(
            registry: AccountRegistry(indexFileURL: indexFileURL ?? tempIndexURL()),
            store: store,
            ensureDirectory: ensureDirectory,
            reaper: reaper)
    }
```

Then append:

```swift
@Suite struct AccountManagerGatewayShutdownTests {

    /// The gateway child's working directory IS the directory AccountReaper is about
    /// to delete, so the shutdown hook must run while that directory still exists.
    /// Asserting on the directory itself — rather than on a recorded call order —
    /// tests the property that actually matters, against the real reaper.
    @Test func shutdownHookRunsWhileTheAccountDirectoryStillExists() async throws {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "gw-reap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }

        let manager = AccountManager(
            registry: AccountRegistry(indexFileURL: home.appending(path: "index.json")),
            store: InMemoryActiveAccountStore(),
            ensureDirectory: { path in
                try FileManager.default.createDirectory(
                    atPath: path, withIntermediateDirectories: true)
            },
            reaper: AccountReaper(home: home))

        let account = try manager.add(label: "Work")
        let accountDir = AccountsRoot.url(home: home).appending(path: account.id).path
        #expect(FileManager.default.fileExists(atPath: accountDir))

        let observed = DirectoryPresence()
        manager.onAccountRemoved = { _ in
            await observed.record(FileManager.default.fileExists(atPath: accountDir))
        }

        _ = manager.remove(accountId: account.id)

        // The hook plus reap run on a detached task; poll rather than fixed-sleep.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await observed.value == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(await observed.value == true, "hook ran after the directory was already reaped")

        while FileManager.default.fileExists(atPath: accountDir) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: accountDir), "reap never ran")
    }
}

private actor DirectoryPresence {
    private(set) var value: Bool?
    func record(_ existed: Bool) { value = existed }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountManagerGatewayShutdownTests`
Expected: FAIL — no `onAccountRemoved` member.

- [ ] **Step 3: Write the implementation**

In `Sources/LogoSwitch/AccountManager.swift`, add the property near the other stored dependencies:

```swift
    /// Called with an account id when it is removed, BEFORE its data directory is
    /// reaped. The app wires this to `GatewayPool.shutdown(accountID:)`: the
    /// gateway child's working directory is the very directory the reaper deletes,
    /// so a live child must be stopped first. A closure rather than a direct pool
    /// reference keeps LogoSwitch independent of LogosGateway.
    public var onAccountRemoved: (@Sendable (String) async -> Void)?
```

In `remove(accountId:)`, run the hook before the reap. The hook is async and `remove` is sync, so await it in a detached task and let the reap follow inside the same task to preserve ordering:

```swift
        if let removed, !removed.isSystemDefault {
            let hook = onAccountRemoved
            let reaper = self.reaper
            Task {
                await hook?(accountId)
                reaper.reap(accountID: accountId)
            }
        }
        return true
```

Note the behavior change: the reap now happens asynchronously rather than inline. That is required for correct ordering. Any existing test asserting the directory is gone the instant `remove` returns must be updated to await the removal.

- [ ] **Step 4: Run the full gate**

Run: `swift test`
Expected: PASS. Expect to update at least one pre-existing reap test for the now-async deletion.

- [ ] **Step 5: Commit**

```bash
git add Sources/LogoSwitch/AccountManager.swift Tests/LogoSwitchTests/AccountManagerTests.swift
git commit -m "feat: stop an account gateway before reaping its data directory"
```

---

### Task 10: Wire the spawn path and the failure-policy banner

**Files:**
- Modify: `Sources/LogoSwitch/ClaudeProcessConfig.swift`
- Create: `Sources/Logos/Views/MainArea/GatewayUnavailableBanner.swift`
- Modify: `Sources/Logos/Views/MainArea/TerminalPaneView.swift`
- Create: `Sources/Logos/Models/GatewayResolution.swift`
- Create: `Tests/LogosTests/GatewayResolutionTests.swift`

**Interfaces:**
- Consumes: `GatewayPool` (Task 7), `AdvancedSettings.gatewayEnabled` / `.gatewayCommand` (Task 8), `Account.upstream` (Task 8), `ClaudeConfigEnvironment.apply(base:configDir:gatewayBaseURL:)` (Task 5).
- Produces:
  - `ClaudeProcessConfig.init(..., gatewayBaseURL: URL?)`
  - `enum GatewayResolution: Sendable, Equatable { case resolved(URL?), blocked(reason: String) }`
  - `GatewayResolution.classify(hasCustomUpstream:error:) -> GatewayResolution`

`ClaudeProcessConfig` is built synchronously inside a SwiftUI `body`, but `pool.acquire` is async — a body cannot await. Acquisition therefore moves into a `.task(id:)` keyed on the account id, storing the outcome in `@State`. That also gives the failure policy a natural home: while unresolved or blocked, the pane renders the banner instead of a terminal.

- [ ] **Step 1: Write the failing test**

Create `Tests/LogosTests/GatewayResolutionTests.swift`:

```swift
import Foundation
import Testing
@testable import Logos

@Suite struct GatewayResolutionTests {

    /// Default upstream: the gateway is only pacing and observability, so losing
    /// it degrades telemetry but must not brick the account.
    @Test nonisolated func failsOpenOnDefaultUpstream() {
        let resolution = GatewayResolution.classify(
            hasCustomUpstream: false,
            error: GatewayResolutionError.unavailable("plugin not installed")
        )
        #expect(resolution == .resolved(nil))
    }

    /// Custom upstream: falling back to api.anthropic.com would send traffic
    /// somewhere the operator did not direct it. Refuse instead.
    @Test nonisolated func failsClosedOnCustomUpstream() {
        let resolution = GatewayResolution.classify(
            hasCustomUpstream: true,
            error: GatewayResolutionError.unavailable("plugin not installed")
        )
        guard case .blocked(let reason) = resolution else {
            Issue.record("expected blocked, got \(resolution)")
            return
        }
        #expect(reason.contains("plugin not installed"))
    }

    @Test nonisolated func successPassesTheURLThrough() {
        let url = URL(string: "http://127.0.0.1:51234")!
        #expect(GatewayResolution.success(url) == .resolved(url))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GatewayResolutionTests`
Expected: FAIL — `cannot find 'GatewayResolution' in scope`.

- [ ] **Step 3: Write the resolution policy**

Create `Sources/Logos/Models/GatewayResolution.swift`:

```swift
import Foundation

public enum GatewayResolutionError: Error, Equatable {
    case unavailable(String)
}

/// Outcome of trying to obtain an account's gateway, and the failure policy that
/// decides what a failure means.
public enum GatewayResolution: Sendable, Equatable {
    /// Spawn claude. `nil` means spawn it direct, with no gateway.
    case resolved(URL?)
    /// Do not spawn claude. Show the reason.
    case blocked(reason: String)

    public static func success(_ url: URL?) -> GatewayResolution { .resolved(url) }

    /// Calibrated to whether the account has a custom upstream, because the two
    /// cases fail differently. With the default upstream the gateway only adds
    /// pacing and observability, so falling back to direct is a degradation.
    /// With a custom upstream, falling back would route traffic to
    /// api.anthropic.com when the operator directed it elsewhere — a policy
    /// violation, not a degradation.
    public static func classify(
        hasCustomUpstream: Bool,
        error: GatewayResolutionError
    ) -> GatewayResolution {
        let detail: String
        switch error {
        case .unavailable(let text): detail = text
        }
        return hasCustomUpstream
            ? .blocked(reason: "Gateway unavailable and this account has a custom upstream: \(detail)")
            : .resolved(nil)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GatewayResolutionTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Thread `gatewayBaseURL` through `ClaudeProcessConfig`**

In `Sources/LogoSwitch/ClaudeProcessConfig.swift`, add the parameter and forward it:

```swift
    public init(
        executablePath: String,
        account: Account? = nil,
        extraArgs: [String] = [],
        workingDirectory: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        gatewayBaseURL: URL? = nil
    ) {
        self.executablePath = executablePath
        self.account = account

        let defaultArgs: [String] = []
        self.arguments = defaultArgs + extraArgs
        self.workingDirectory = workingDirectory

        self.environment = ClaudeConfigEnvironment.apply(
            base: baseEnvironment,
            configDir: account.flatMap(\.spawnConfigDir),
            gatewayBaseURL: gatewayBaseURL
        )
    }
```

- [ ] **Step 6: Add the banner view**

Create `Sources/Logos/Views/MainArea/GatewayUnavailableBanner.swift`:

```swift
import SwiftUI

/// Surfaces the gateway failure policy. Fail-open renders this ABOVE a live
/// terminal (the account still works, unmetered); fail-closed renders it INSTEAD
/// of one. Uses the same in-window banner slot as NoActiveAccountBanner.
struct GatewayUnavailableBanner: View {

    let reason: String
    /// true when claude was refused entirely (custom upstream configured).
    let isBlocking: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isBlocking ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isBlocking ? .red : .yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(isBlocking ? "Gateway required but unavailable" : "Running without a gateway")
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .accessibilityIdentifier("logos.gateway.banner")
    }
}
```

- [ ] **Step 7: Wire `TerminalPaneView`**

In `Sources/Logos/Views/MainArea/TerminalPaneView.swift`:

Add state next to the existing `@State private var sessionState`:

```swift
    /// Gateway outcome for the active account. Resolved asynchronously because
    /// GatewayPool.acquire is async and a SwiftUI body cannot await. nil means
    /// "still resolving".
    @State private var gateway: GatewayResolution?
```

Inside the `if let active = ...` branch, wrap the existing content so the pane resolves before spawning. Replace the direct `ClaudeProcessConfig(...)` construction with:

```swift
                switch gateway {
                case .none:
                    ProgressView("Preparing gateway")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .blocked(let reason):
                    GatewayUnavailableBanner(reason: reason, isBlocking: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                case .resolved(let gatewayURL):
                    VStack(spacing: 0) {
                        if gatewayURL == nil && advanced.gatewayEnabled && !active.isSystemDefault {
                            GatewayUnavailableBanner(
                                reason: "No gateway is running for this account; requests go direct and are not paced.",
                                isBlocking: false
                            )
                        }
                        let processConfig = ClaudeProcessConfig(
                            executablePath: claudePath,
                            account: active,
                            extraArgs: advanced.claudeExtraArgs,
                            workingDirectory: workspace.rootNode?.path,
                            baseEnvironment: LoginShellEnvironment.resolve(),
                            gatewayBaseURL: gatewayURL
                        )
                        SwiftTermView(
                            config: config,
                            processConfig: processConfig,
                            engine: engine,
                            accountManager: accountMgr,
                            sessionState: sessionState,
                            onSessionSpawned: { usage.setSessionId($0) }
                        )
                        .background(Color.black)
                        // Include the gateway URL so a changed gateway re-spawns claude
                        // rather than leaving it pointed at a dead port.
                        .id("\(active.id)-\(claudePath)-\(workspace.rootNode?.path ?? "")-\(gatewayURL?.absoluteString ?? "direct")-\(sessionState.generation)")
                    }
                }
```

Add the acquisition task to the same `Group`, keyed so a switch re-resolves:

```swift
        .task(id: WindowAccountResolver.resolve(
            selected: windowSelection.accountId,
            accounts: accountMgr.accounts
        )?.id) {
            guard let active = WindowAccountResolver.resolve(
                selected: windowSelection.accountId,
                accounts: accountMgr.accounts
            ) else { return }

            guard advanced.gatewayEnabled else {
                gateway = .resolved(nil)
                return
            }

            let command = advanced.gatewayCommand ?? GatewayCommandResolver.resolve()
            let upstream = active.upstream.flatMap(URL.init(string:))
            do {
                let url = try await gatewayPool.acquire(
                    account: active,
                    command: command,
                    upstream: upstream
                )
                gateway = .success(url)
            } catch {
                gateway = GatewayResolution.classify(
                    hasCustomUpstream: active.upstream != nil,
                    error: .unavailable(error.localizedDescription)
                )
            }
        }
```

Add `import LogosGateway` at the top of the file, and inject the pool. The pool is app-lifetime state, so declare it in `LogosApp` as a `@State private var gatewayPool = GatewayPool()` and pass it down via `.environment(...)`, reading it here with `@Environment(GatewayPool.self) private var gatewayPool`. Wire `accountMgr.onAccountRemoved = { [gatewayPool] id in await gatewayPool.shutdown(accountID: id) }` at the same place the `AccountManager` is constructed in `LogosApp`, and call `await gatewayPool.shutdownAll()` from the app's termination handler so no child is orphaned.

- [ ] **Step 8: Run the full gate**

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Verify the build compiles for Track B**

Run: `xcodegen generate && xcodebuild -project Logos.xcodeproj -scheme Logos -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

This requires XcodeGen (`brew install xcodegen`), an Apple Development signing identity, and the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`). If any is missing on this machine, record that Track B was not verified rather than reporting it green.

- [ ] **Step 10: Commit**

```bash
git add Sources/LogoSwitch/ClaudeProcessConfig.swift Sources/Logos/Models/GatewayResolution.swift Sources/Logos/Views/MainArea Sources/Logos/App/LogosApp.swift Tests/LogosTests/GatewayResolutionTests.swift
git commit -m "feat: route isolated accounts through per-account gateways at spawn"
```

---

### Task 11: End-to-end verification against the acceptance criteria

**Files:**
- Modify: `Tests/LogosSmokeTests/` (add gateway assertions to the existing smoke)
- Modify: `CLAUDE.md` (document the gateway layer)

**Interfaces:**
- Consumes: everything above.
- Produces: no new API.

- [ ] **Step 1: Add the gateway trail to the Track A smoke**

The smoke already collects `[UnifiedLogReader.Event]` for the critical flow and matches with
`UnifiedLogReader.contains(_:category:message:)`. Add an assertion to
`Tests/LogosSmokeTests/SmokeTests.swift` inside `criticalFlowLifecycle()`, after the existing
events are gathered (reuse whatever local the suite already binds them to — named `events` below):

```swift
        // Gateway layer (spec 2026-07-31): an isolated account must acquire a
        // gateway, and it must happen BEFORE claude is spawned — a claude that
        // starts first would connect direct and never be paced.
        #expect(
            UnifiedLogReader.contains(events, category: "gateway-pool", message: "gateway acquired")
                || UnifiedLogReader.contains(events, category: "gateway-pool", message: "system-default account excluded"),
            "no gateway-pool decision recorded:\n\(Self.dump(events))"
        )

        if let acquired = events.firstIndex(where: {
            $0.category == "gateway-pool" && $0.message.contains("gateway acquired")
        }), let spawned = events.firstIndex(where: {
            $0.category == "terminal" && $0.message.contains("claude spawned")
        }) {
            #expect(acquired < spawned, "gateway acquired after claude spawned:\n\(Self.dump(events))")
        }
```

Adjust the `category` / `message` fragment of the claude-spawn event to whatever the existing
suite already asserts on for the spawn step — do not invent a new log line. If the smoke launches
with the system-default account (the likely default), the first `#expect` passes via the
`excluded` branch and the ordering check is correctly skipped.

Remember `/usr/bin/log` needs its absolute path when inspecting manually — `log` is a zsh builtin
that shadows the binary and returns empty.

- [ ] **Step 2: Run the smoke**

Run: `make smoke`
Expected: PASS. If `claude` is not installed on this machine, the smoke degrades with a visible warning — record that rather than claiming a pass.

- [ ] **Step 3: Manually verify the two headline criteria**

With two isolated accounts open in separate windows:

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -E "127.0.0.1:(5|6)[0-9]{4}"
ls -d ~/.logos/accounts/*/hot-limit 2>/dev/null
```

Expected: two distinct listening ports, two distinct `hot-limit` state directories. Confirm the global `8787` proxy is still running and still used by main only.

- [ ] **Step 4: Document in `CLAUDE.md`**

Add a short subsection under the existing architecture notes covering: the pool's per-account granularity, the deliberate main exclusion and why (settings-file `env` outranks process env), the `hot-limit` state directory location, and the Remote Control trade-off.

- [ ] **Step 5: Run the full gate one final time**

Run: `rm -rf .build && swift test`
Expected: PASS. The clean rebuild guards against a cached false-green.

- [ ] **Step 6: Commit**

```bash
git add Tests/LogosSmokeTests CLAUDE.md
git commit -m "test: assert per-account gateway trail in the headless smoke"
```

---

## Verification against the spec's acceptance criteria

| # | Criterion | Covered by |
|---|-----------|-----------|
| 1 | Two accounts, two gateways, no cross-throttling | Task 7 (`distinctAccountsGetDistinctPorts`), Task 11 Step 3 |
| 2 | Isolated account reports the Logos-assigned base URL | Task 5, Task 10 |
| 3 | Main's routing unchanged | Task 7 (`systemDefaultAccountGetsNoGateway`), Task 11 Step 3 |
| 4 | No inheritance of an exported `ANTHROPIC_BASE_URL` | Task 5 (`stripsInheritedBaseURLWhenNoGateway`, `defaultArgumentAlsoStrips`) |
| 5 | Removal stops the gateway first; no orphans at exit | Task 9, Task 10 Step 7 (`shutdownAll`) |
| 6 | Plugin absent: fail-open by default, fail-closed on custom upstream | Task 10 (`GatewayResolutionTests`) |

Spec edge cases beyond the numbered criteria: crash restart with bounded backoff is Task 6
(`GatewaySupervisionTests`); the port-race retry is Task 3 (`allocate(maxAttempts:)`); the
five-second linger is Task 7 (`GatewayPool.init(linger:)`); the Remote Control trade-off is
documented in Task 8 Step 5 (Settings) and Task 11 Step 4 (`CLAUDE.md`).
