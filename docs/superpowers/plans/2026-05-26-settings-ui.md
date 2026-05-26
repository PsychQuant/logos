# Sub-plan H — Settings UI (Wire All The Knobs)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task.

**Goal:** Replace the 6-tab placeholder Settings window (sub-plan A Task 10) with real, working settings UI. Each tab edits real models from prior sub-plans — `TerminalConfig` (B), `AutoHandleEngine` rules (D), `AccountManager` (E), `WorkspaceConfig` builds (G) — plus new General/Advanced settings introduced here. All changes persist immediately.

**Why this matters:** Today users are stuck with hardcoded defaults — Menlo 13pt, the 5 hardcoded auto-handle rules, no way to add custom accounts beyond the import flow, no way to disable telemetry (none yet, but architecturally), no way to override the claude binary path. H makes Logos configurable instead of opinionated.

**Resolved design decisions:**
- **Persistence**: each settings domain has its own file under `~/Library/Application Support/Logos/`. Reason: cleaner than one mega-settings file; sub-plans evolve independently.
  - `general.json`, `terminal.json`, `autohandle.json`, `live-preview.json`, `advanced.json`
  - Accounts already persisted via Keychain + UserDefaults from sub-plan E — Settings tab is a different VIEW on the same data
- **Live apply**: changes apply immediately (no Save/Cancel buttons except where explicitly destructive). Matches macOS conventions.
- **Scope cuts for v1.0**:
  - Auto-handle: toggle each of the 5 hardcoded rules on/off. **No custom regex rules yet** — defer to v1.1.
  - Live preview: edit the `WorkspaceConfig.builds` of the CURRENT workspace only (no global build defaults beyond the hardcoded `.tex`/`.md`).
  - Advanced: claude binary path override + log level. **No telemetry / crash reporting** — defer.
  - General: theme picker (system/light/dark) + launch behavior. **No hotkey customization** — defer.

**Prerequisites:**
- ✅ Sub-plan A (SettingsWindow stub with 6 tabs)
- ✅ Sub-plan B (TerminalConfig)
- ✅ Sub-plan D (AutoHandleEngine + AutoHandleRule)
- ✅ Sub-plan E (AccountManager)
- ✅ Sub-plan G (WorkspaceConfig)

**Tech Stack:** Swift 6, SwiftUI Forms, JSON persistence via `Codable`

**What this sub-plan does NOT include:**
- Custom regex auto-handle rules (v1.1)
- Per-workspace setting overrides (v1.1)
- Hotkey customization (vNext)
- Telemetry / crash reporting (vNext)
- iCloud settings sync (vNext)

---

## File Structure

```
logos/
├── Sources/Logos/
│   ├── Models/
│   │   ├── GeneralSettings.swift                              NEW — @Observable, theme + launch
│   │   ├── AdvancedSettings.swift                             NEW — @Observable, claude path + log
│   │   └── AutoHandleEngine.swift                             MODIFY — rules become mutable
│   ├── Services/
│   │   └── SettingsPersistence.swift                          NEW — generic JSON load/save
│   ├── Views/
│   │   └── Settings/
│   │       ├── SettingsWindow.swift                           REPLACE — full TabView with real tabs
│   │       ├── GeneralSettingsTab.swift                       NEW
│   │       ├── TerminalSettingsTab.swift                      NEW
│   │       ├── AutoHandleSettingsTab.swift                    NEW
│   │       ├── AccountsSettingsTab.swift                      NEW — reuses AccountSwitcherSheet
│   │       ├── LivePreviewSettingsTab.swift                   NEW
│   │       └── AdvancedSettingsTab.swift                      NEW
│   └── App/
│       └── MainScene.swift                                    MODIFY — inject new settings models
├── Tests/LogosTests/
│   ├── GeneralSettingsTests.swift                             NEW
│   ├── AdvancedSettingsTests.swift                            NEW
│   ├── SettingsPersistenceTests.swift                         NEW
│   └── AutoHandleEngineRuleToggleTests.swift                  NEW — extends existing engine tests
```

---

## Task 1: SettingsPersistence (generic Codable JSON I/O) + tests

**Files:**
- Create: `Sources/Logos/Services/SettingsPersistence.swift`
- Test: `Tests/LogosTests/SettingsPersistenceTests.swift`

**Purpose:** One small wrapper that load/save any `Codable` to `~/Library/Application Support/Logos/<filename>.json`. Tests inject a temp dir.

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("SettingsPersistence", .serialized)
struct SettingsPersistenceTests {

    struct TestSettings: Codable, Equatable {
        let n: Int
        let s: String
    }

    @Test("save then load returns same value")
    func roundtrip() throws {
        let dir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)"
        let store = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let original = TestSettings(n: 42, s: "hello")
        try store.save(original, to: "test.json")
        let loaded: TestSettings? = try store.load(from: "test.json")
        #expect(loaded == original)
    }

    @Test("load missing returns nil")
    func loadMissing() throws {
        let dir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SettingsPersistence(directory: dir)
        let loaded: TestSettings? = try store.load(from: "nonexistent.json")
        #expect(loaded == nil)
    }

    @Test("save creates directory if needed")
    func createsDir() throws {
        let dir = NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)/nested/path"
        let store = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "logos-sp-\(UUID().uuidString)") }
        try store.save(TestSettings(n: 1, s: "x"), to: "x.json")
        #expect(FileManager.default.fileExists(atPath: "\(dir)/x.json"))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct SettingsPersistence {

    public static let defaultDirectory: String = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        return "\(appSupport)/Logos"
    }()

    public let directory: String

    public init(directory: String = SettingsPersistence.defaultDirectory) {
        self.directory = directory
    }

    public func save<T: Encodable>(_ value: T, to filename: String) throws {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: URL(fileURLWithPath: "\(directory)/\(filename)"))
    }

    public func load<T: Decodable>(from filename: String) throws -> T? {
        let path = "\(directory)/\(filename)"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(T.self, from: data)
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter SettingsPersistenceTests
git add Sources/Logos/Services/SettingsPersistence.swift Tests/LogosTests/SettingsPersistenceTests.swift
git commit -m "feat(settings): H-Task 1 — SettingsPersistence Codable JSON wrapper + 3 tests

~/Library/Application Support/Logos/ as default dir. Pretty-printed
+ sorted keys JSON output. Auto-creates directory tree. load() returns
nil for missing files (vs throwing) — settings absence is a normal
initial state."
```

---

## Task 2: GeneralSettings model + tests

**Files:**
- Create: `Sources/Logos/Models/GeneralSettings.swift`
- Test: `Tests/LogosTests/GeneralSettingsTests.swift`

**Purpose:** Theme (system/light/dark) + launch behavior (restore last window vs blank).

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("GeneralSettings", .serialized)
@MainActor
struct GeneralSettingsTests {

    @Test("defaults")
    func defaults() {
        let s = GeneralSettings(persistence: makePersistence())
        #expect(s.theme == .system)
        #expect(s.restoreLastWorkspaceOnLaunch == true)
    }

    @Test("change persists immediately")
    func changesPersist() throws {
        let dir = NSTemporaryDirectory() + "logos-gs-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = GeneralSettings(persistence: p)
        s1.theme = .dark
        s1.restoreLastWorkspaceOnLaunch = false

        let s2 = GeneralSettings(persistence: p)
        #expect(s2.theme == .dark)
        #expect(s2.restoreLastWorkspaceOnLaunch == false)
    }

    @Test("theme cases")
    func themeCases() {
        #expect(GeneralSettings.Theme.allCases.count == 3)
    }

    private func makePersistence() -> SettingsPersistence {
        let dir = NSTemporaryDirectory() + "logos-gs-\(UUID().uuidString)"
        return SettingsPersistence(directory: dir)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
public final class GeneralSettings {

    public enum Theme: String, CaseIterable, Codable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    @ObservationIgnored private let persistence: SettingsPersistence
    private static let filename = "general.json"

    @ObservationIgnored private var _theme: Theme = .system
    public var theme: Theme {
        get { _theme }
        set { _theme = newValue; save() }
    }

    @ObservationIgnored private var _restoreLastWorkspaceOnLaunch: Bool = true
    public var restoreLastWorkspaceOnLaunch: Bool {
        get { _restoreLastWorkspaceOnLaunch }
        set { _restoreLastWorkspaceOnLaunch = newValue; save() }
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _theme = dto.theme
            _restoreLastWorkspaceOnLaunch = dto.restoreLastWorkspaceOnLaunch
        }
    }

    private func save() {
        let dto = PersistedDTO(
            theme: _theme,
            restoreLastWorkspaceOnLaunch: _restoreLastWorkspaceOnLaunch
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let theme: Theme
        let restoreLastWorkspaceOnLaunch: Bool
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter GeneralSettingsTests
git add Sources/Logos/Models/GeneralSettings.swift Tests/LogosTests/GeneralSettingsTests.swift
git commit -m "feat(settings): H-Task 2 — GeneralSettings (theme + restore-workspace) + 3 tests

@Observable with computed properties backed by @ObservationIgnored
+ save() on set (live-apply pattern — same as WindowLayoutState).

Theme: system/light/dark with ColorScheme bridge for SwiftUI .preferredColorScheme.
PersistedDTO struct for Codable separation from live model."
```

---

## Task 3: AdvancedSettings + tests

**Files:**
- Create: `Sources/Logos/Models/AdvancedSettings.swift`
- Test: `Tests/LogosTests/AdvancedSettingsTests.swift`

**Purpose:** Claude binary path override (string), log level (debug/info/warn/error).

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("AdvancedSettings", .serialized)
@MainActor
struct AdvancedSettingsTests {

    @Test("defaults")
    func defaults() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        #expect(s.claudePathOverride == nil)
        #expect(s.logLevel == .info)
    }

    @Test("override persists")
    func overridePersists() throws {
        let dir = tempDir()
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let s1 = AdvancedSettings(persistence: p)
        s1.claudePathOverride = "/opt/homebrew/bin/claude"
        s1.logLevel = .debug

        let s2 = AdvancedSettings(persistence: p)
        #expect(s2.claudePathOverride == "/opt/homebrew/bin/claude")
        #expect(s2.logLevel == .debug)
    }

    @Test("empty string treated as nil")
    func emptyAsNil() {
        let s = AdvancedSettings(persistence: SettingsPersistence(directory: tempDir()))
        s.claudePathOverride = ""
        #expect(s.claudePathOverride == nil)
    }

    private func tempDir() -> String {
        NSTemporaryDirectory() + "logos-as-\(UUID().uuidString)"
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation
import Observation

@Observable
@MainActor
public final class AdvancedSettings {

    public enum LogLevel: String, CaseIterable, Codable, Identifiable, Sendable {
        case debug, info, warn, error
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
    }

    @ObservationIgnored private let persistence: SettingsPersistence
    private static let filename = "advanced.json"

    @ObservationIgnored private var _claudePathOverride: String?
    public var claudePathOverride: String? {
        get { _claudePathOverride }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            _claudePathOverride = (trimmed?.isEmpty == false) ? trimmed : nil
            save()
        }
    }

    @ObservationIgnored private var _logLevel: LogLevel = .info
    public var logLevel: LogLevel {
        get { _logLevel }
        set { _logLevel = newValue; save() }
    }

    public init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        if let dto: PersistedDTO = try? persistence.load(from: Self.filename) {
            _claudePathOverride = dto.claudePathOverride
            _logLevel = dto.logLevel
        }
    }

    private func save() {
        let dto = PersistedDTO(
            claudePathOverride: _claudePathOverride,
            logLevel: _logLevel
        )
        try? persistence.save(dto, to: Self.filename)
    }

    private struct PersistedDTO: Codable {
        let claudePathOverride: String?
        let logLevel: LogLevel
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
swift test --filter AdvancedSettingsTests
git add Sources/Logos/Models/AdvancedSettings.swift Tests/LogosTests/AdvancedSettingsTests.swift
git commit -m "feat(settings): H-Task 3 — AdvancedSettings (claude path + log level) + 3 tests

Empty-string-treated-as-nil semantics for claudePathOverride (user
clearing the field should disable the override, not save empty string).
LogLevel enum scaffold for future log subsystem."
```

---

## Task 4: Make AutoHandleEngine rules mutable + persistent + tests

**Files:**
- Modify: `Sources/Logos/Models/AutoHandleEngine.swift`
- Test: `Tests/LogosTests/AutoHandleEngineRuleToggleTests.swift`

**Purpose:** Sub-plan D's `AutoHandleEngine` has `disableRule(id:)` / `enableRule(id:)` but disabled set is in-memory only. Persist it so user toggles survive relaunch.

- [ ] **Step 1: Failing test**

```swift
import Testing
import Foundation
@testable import Logos

@Suite("AutoHandleEngine rule toggle persistence", .serialized)
@MainActor
struct AutoHandleEngineRuleToggleTests {

    @Test("disabled rule persists across new engine init")
    func disabledPersists() throws {
        let dir = NSTemporaryDirectory() + "logos-ae-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let e1 = AutoHandleEngine(persistence: p)
        e1.disableRule(id: "rate-limit")
        #expect(e1.disabledRuleIDs.contains("rate-limit"))

        let e2 = AutoHandleEngine(persistence: p)
        #expect(e2.disabledRuleIDs.contains("rate-limit"))
    }

    @Test("enable removes from persisted disabled set")
    func enableRemoves() throws {
        let dir = NSTemporaryDirectory() + "logos-ae-\(UUID().uuidString)"
        let p = SettingsPersistence(directory: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let e1 = AutoHandleEngine(persistence: p)
        e1.disableRule(id: "rate-limit")
        e1.enableRule(id: "rate-limit")

        let e2 = AutoHandleEngine(persistence: p)
        #expect(!e2.disabledRuleIDs.contains("rate-limit"))
    }
}
```

- [ ] **Step 2: Modify `AutoHandleEngine.swift`**

Add `persistence` parameter to init, load disabled set on init, save on disable/enable changes (NOT on runaway-auto-disable — that's runtime-only and should reset on relaunch).

```swift
// Add to AutoHandleEngine:

@ObservationIgnored private let persistence: SettingsPersistence?
private static let filename = "autohandle.json"

public init(
    rules: [AutoHandleRule] = AutoHandleRule.defaultRuleset,
    persistence: SettingsPersistence? = SettingsPersistence()
) {
    self.rules = rules
    self.persistence = persistence
    if let p = persistence,
       let dto: PersistedDTO = try? p.load(from: Self.filename) {
        self.disabledRuleIDs = Set(dto.disabledRuleIDs)
    }
}

public func disableRule(id: String) {
    disabledRuleIDs.insert(id)
    saveUserToggleState()
}

public func enableRule(id: String) {
    disabledRuleIDs.remove(id)
    saveUserToggleState()
}

// Runaway auto-disable: separate code path that does NOT persist.
// (Existing logic in processChunk continues to insert into disabledRuleIDs
// WITHOUT calling saveUserToggleState — user must explicitly toggle to persist.)

private func saveUserToggleState() {
    let dto = PersistedDTO(disabledRuleIDs: Array(disabledRuleIDs).sorted())
    try? persistence?.save(dto, to: Self.filename)
}

private struct PersistedDTO: Codable {
    let disabledRuleIDs: [String]
}
```

**Important nuance:** runaway-auto-disable should NOT persist (it's a transient response to a misbehaving session; user shouldn't have rate-limit silently disabled forever on next launch). Only USER-initiated disables persist.

- [ ] **Step 3: Run all engine tests** (existing + new)

```bash
swift test --filter AutoHandleEngine
```

Expected: 5 prior + 2 new = 7 pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Models/AutoHandleEngine.swift \
        Tests/LogosTests/AutoHandleEngineRuleToggleTests.swift
git commit -m "feat(settings): H-Task 4 — AutoHandleEngine persists user-toggled rules

User-initiated disable/enable now persist to ~/Library/Application
Support/Logos/autohandle.json. Runaway auto-disable (3 fires in 30s)
remains transient — user's intentional preferences shouldn't be
overridden by runtime panic.

7 engine tests pass (5 prior + 2 new on persistence)."
```

---

## Task 5: General + Terminal + Advanced settings tabs

**Files:**
- Create: `Sources/Logos/Views/Settings/GeneralSettingsTab.swift`
- Create: `Sources/Logos/Views/Settings/TerminalSettingsTab.swift`
- Create: `Sources/Logos/Views/Settings/AdvancedSettingsTab.swift`

- [ ] **Step 1: `GeneralSettingsTab.swift`**

```swift
import SwiftUI

struct GeneralSettingsTab: View {
    @Environment(GeneralSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(GeneralSettings.Theme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Launch") {
                Toggle("Restore last workspace on launch",
                       isOn: $settings.restoreLastWorkspaceOnLaunch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}
```

- [ ] **Step 2: `TerminalSettingsTab.swift`**

```swift
import SwiftUI

struct TerminalSettingsTab: View {
    @Environment(TerminalConfig.self) private var config

    var body: some View {
        @Bindable var config = config

        Form {
            Section("Font") {
                TextField("Font name", text: $config.fontName)
                    .help("Any installed monospaced font (e.g. Menlo, JetBrains Mono, SF Mono)")
                HStack {
                    Text("Size")
                    Slider(value: $config.fontSize, in: 9...24, step: 1)
                    Text("\(Int(config.fontSize))pt")
                        .monospacedDigit()
                        .frame(width: 36)
                }
            }

            Section("Colors") {
                ColorRow(label: "Background", hex: $config.backgroundColorHex)
                ColorRow(label: "Foreground", hex: $config.foregroundColorHex)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}

private struct ColorRow: View {
    let label: String
    @Binding var hex: String

    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            TextField("Hex (#rrggbb)", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            swatch
        }
    }

    private var swatch: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(parseHex(hex) ?? Color.gray)
            .frame(width: 24, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
            )
    }

    private func parseHex(_ hex: String) -> Color? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}
```

- [ ] **Step 3: `AdvancedSettingsTab.swift`**

```swift
import SwiftUI

struct AdvancedSettingsTab: View {
    @Environment(AdvancedSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Claude CLI") {
                TextField(
                    "Path override (leave empty for $PATH lookup)",
                    text: Binding(
                        get: { settings.claudePathOverride ?? "" },
                        set: { settings.claudePathOverride = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .help("If 'which claude' doesn't find the right binary, set its absolute path here. e.g. /opt/homebrew/bin/claude")

                if let path = settings.claudePathOverride {
                    Label(
                        FileManager.default.fileExists(atPath: path) ? "File exists" : "File NOT found at that path",
                        systemImage: FileManager.default.fileExists(atPath: path) ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .green : .red)
                }
            }

            Section("Logging") {
                Picker("Log level", selection: $settings.logLevel) {
                    ForEach(AdvancedSettings.LogLevel.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                Text("Logs at: ~/Library/Logs/Logos/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 320)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Views/Settings/{General,Terminal,Advanced}SettingsTab.swift
git commit -m "feat(settings): H-Task 5 — General/Terminal/Advanced tabs

General: theme segmented picker + restore-workspace toggle.
Terminal: font name + size slider + bg/fg hex with live swatch preview.
Advanced: claude path override (live exists-check), log level.

All Form-based + .grouped style. 460x320 frame for consistent
Preferences-window sizing."
```

---

## Task 6: Auto-handle settings tab (toggle each rule)

**Files:**
- Create: `Sources/Logos/Views/Settings/AutoHandleSettingsTab.swift`

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct AutoHandleSettingsTab: View {
    @Environment(AutoHandleEngine.self) private var engine

    var body: some View {
        Form {
            Section {
                ForEach(AutoHandleRule.defaultRuleset) { rule in
                    RuleRow(rule: rule, engine: engine)
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Toggling here persists across launches. Runaway protection (3 fires in 30s → auto-disable) is transient and resets on next launch.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 380)
    }
}

private struct RuleRow: View {
    let rule: AutoHandleRule
    let engine: AutoHandleEngine

    var isEnabled: Binding<Bool> {
        Binding(
            get: { !engine.disabledRuleIDs.contains(rule.id) },
            set: { newValue in
                if newValue { engine.enableRule(id: rule.id) }
                else { engine.disableRule(id: rule.id) }
            }
        )
    }

    var body: some View {
        Toggle(isOn: isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.body)
                Text("pattern: \(rule.pattern)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text("response: \(rule.response.replacingOccurrences(of: "\n", with: "↵"))  ·  cooldown: \(Int(rule.cooldown))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/Logos/Views/Settings/AutoHandleSettingsTab.swift
git commit -m "feat(settings): H-Task 6 — AutoHandleSettingsTab with 5 rule toggles

Each rule: switch toggle + pattern + response + cooldown displayed.
Footer clarifies runaway vs user-toggle persistence semantics.

540x380 frame (wider than other tabs to fit pattern strings)."
```

---

## Task 7: Accounts + Live Preview tabs

**Files:**
- Create: `Sources/Logos/Views/Settings/AccountsSettingsTab.swift`
- Create: `Sources/Logos/Views/Settings/LivePreviewSettingsTab.swift`

- [ ] **Step 1: `AccountsSettingsTab.swift` — reuses sub-plan E's switcher view**

```swift
import SwiftUI

struct AccountsSettingsTab: View {
    var body: some View {
        AccountSwitcherSheet()
            .frame(width: 480, height: 360)
    }
}
```

(Trivial — same widget as the status-bar popover. DRY.)

- [ ] **Step 2: `LivePreviewSettingsTab.swift`**

```swift
import SwiftUI

struct LivePreviewSettingsTab: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var configText: String = ""
    @State private var loadError: String?
    @State private var saveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace build commands")
                .font(.headline)
            Text("Edit `.logosconfig.yaml` for the current workspace. Logos auto-rebuilds PDFs based on these rules.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let root = workspace.rootNode {
                Text(root.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("No workspace open. Open one via File → Open Workspace…")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextEditor(text: $configText)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
                .frame(minHeight: 160)
                .disabled(workspace.rootNode == nil)

            if let err = loadError {
                Text(err).foregroundStyle(.red).font(.caption)
            }
            if let status = saveStatus {
                Text(status).foregroundStyle(.green).font(.caption)
            }

            HStack {
                Button("Reload from disk") { load() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.rootNode == nil)
            }
        }
        .padding(16)
        .frame(width: 540, height: 400)
        .onAppear { load() }
    }

    private func load() {
        guard let root = workspace.rootNode else {
            configText = ""
            return
        }
        let path = "\(root.path)/.logosconfig.yaml"
        if FileManager.default.fileExists(atPath: path) {
            do {
                configText = try String(contentsOfFile: path, encoding: .utf8)
                loadError = nil
            } catch {
                loadError = "Read failed: \(error)"
            }
        } else {
            configText = """
            # .logosconfig.yaml — workspace build commands
            # Defaults handle .tex (latexmk) and .md (pandoc).
            # Add custom rules below.
            #
            # builds:
            #   - source: "*.tex"
            #     command: latexmk -pdf -interaction=nonstopmode {source}
            #     preview: "{stem}.pdf"
            """
        }
    }

    private func save() {
        guard let root = workspace.rootNode else { return }
        let path = "\(root.path)/.logosconfig.yaml"
        do {
            try configText.write(toFile: path, atomically: true, encoding: .utf8)
            saveStatus = "Saved at \(Date().formatted(.dateTime.hour().minute().second()))"
            loadError = nil
        } catch {
            loadError = "Save failed: \(error)"
            saveStatus = nil
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Views/Settings/{Accounts,LivePreview}SettingsTab.swift
git commit -m "feat(settings): H-Task 7 — Accounts (reuse switcher) + LivePreview YAML editor tabs

AccountsSettingsTab: 1-line view — embeds AccountSwitcherSheet from
sub-plan E. Same widget, two entry points (status bar + settings).

LivePreviewSettingsTab: TextEditor over current workspace's
.logosconfig.yaml. Shows scaffolded comment when file missing.
Reload + Save buttons. Disabled when no workspace open."
```

---

## Task 8: Replace SettingsWindow with real TabView

**Files:**
- Replace: `Sources/Logos/Views/Settings/SettingsWindow.swift`

- [ ] **Step 1: Rewrite**

```swift
import SwiftUI

struct SettingsWindow: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gear") }

            TerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "apple.terminal") }

            AutoHandleSettingsTab()
                .tabItem { Label("Auto-handle", systemImage: "bolt") }

            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "person.2") }

            LivePreviewSettingsTab()
                .tabItem { Label("Live preview", systemImage: "doc.richtext") }

            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.adjustable") }
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build
```

Expected: SUCCESS.

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Views/Settings/SettingsWindow.swift
git commit -m "feat(settings): H-Task 8 — replace SettingsWindow stub with real 6-tab view

All 6 tab placeholders from sub-plan A Task 10 now resolve to real
implementations. Each tab uses environment-injected settings models
(GeneralSettings, TerminalConfig, AutoHandleEngine, AccountManager,
WorkspaceModel, AdvancedSettings)."
```

---

## Task 9: MainScene wires new settings models + cmd+, smoke

**Files:**
- Modify: `Sources/Logos/App/MainScene.swift`

- [ ] **Step 1: Inject GeneralSettings + AdvancedSettings + thread AutoHandleEngine persistence**

```swift
@State private var generalSettings = GeneralSettings()
@State private var advancedSettings = AdvancedSettings()
// AutoHandleEngine init now takes persistence — update its construction
@State private var autoHandleEngine = AutoHandleEngine()  // default persistence

// In body, add to .environment chain:
.environment(generalSettings)
.environment(advancedSettings)

// Apply theme:
.preferredColorScheme(generalSettings.theme.colorScheme)
```

- [ ] **Step 2: Wire TerminalConfig.claudePathOverride from AdvancedSettings**

In `TerminalConfig`, change the resolver to consult `AdvancedSettings.claudePathOverride` when no `claudePathOverride` set on the config itself. Simplest path: `TerminalConfig` reads `AdvancedSettings` at resolution time.

OR cleaner: `TerminalConfig.resolvedClaudePath` accepts an optional `AdvancedSettings` argument.

For minimal disruption, modify `TerminalPaneView` to choose path:

```swift
struct TerminalPaneView: View {
    @Environment(TerminalConfig.self) private var config
    @Environment(AdvancedSettings.self) private var advanced
    @Environment(AutoHandleEngine.self) private var engine
    @Environment(AccountManager.self) private var accountMgr

    var body: some View {
        let effectivePath = advanced.claudePathOverride ?? config.resolvedClaudePath
        Group {
            if let active = accountMgr.active, let claudePath = effectivePath {
                let processConfig = ClaudeProcessConfig(executablePath: claudePath, account: active)
                SwiftTermView(config: config, processConfig: processConfig, engine: engine, accountManager: accountMgr)
                    .background(Color.black)
                    .id("\(active.id)-\(claudePath)")  // recreate on path or account change
            } else if effectivePath == nil {
                ClaudeNotFoundBanner()
            } else {
                NoActiveAccountBanner()
            }
        }
    }
}
```

- [ ] **Step 3: Smoke**

```bash
swift build -c release
# Bundle + open
```

Test each tab in cmd+, settings:
- General: switch theme → window appearance changes immediately
- Terminal: change font name → terminal pane re-renders (may need ⌘W close and re-open the window to apply since SwiftTermView only re-applies in updateNSView triggered by config changes)
- Auto-handle: toggle a rule off → engine.disabledRuleIDs includes it → relaunch → still disabled
- Accounts: see existing accounts; add/remove works
- Live preview: edit .logosconfig.yaml → save → next PDF build uses new rules
- Advanced: set claude path override → terminal recreates with new path

- [ ] **Step 4: Screenshot**

Save to `docs/screenshots/settings-window.png`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(settings): H-Task 9 — MainScene injects all settings models + cmd+, smoke

GeneralSettings + AdvancedSettings @State in MainScene.
.preferredColorScheme(generalSettings.theme.colorScheme) applies
theme app-wide.

TerminalPaneView consults AdvancedSettings.claudePathOverride first,
falls back to TerminalConfig.resolvedClaudePath (which is the
'which claude' result). .id() includes path so override change
forces clean recreate.

Live smoke verified all 6 tabs end-to-end. docs/screenshots/
settings-window.png captures."
```

---

## Task 10: README + final regression

- [ ] **Step 1: README update**

Add to status block:

```markdown
**Sub-plan H — Settings UI: COMPLETE ✅**
- 6-tab Preferences window (⌘,): General, Terminal, Auto-handle, Accounts, Live preview, Advanced
- General: theme + restore-workspace
- Terminal: font name + size + bg/fg hex (live swatch)
- Auto-handle: per-rule on/off (persists across launches; runaway disable is transient)
- Accounts: list + add/delete (same widget as ⌘K switcher, embedded)
- Live preview: edit current workspace's `.logosconfig.yaml`
- Advanced: claude binary path override (with live exists-check) + log level
- All changes apply immediately; persisted to `~/Library/Application Support/Logos/*.json`
```

- [ ] **Step 2: Final regression**

```bash
swift test
```

Cumulative ~100 tests.

- [ ] **Step 3: Push**

```bash
git add -A
git commit -m "docs(settings): sub-plan H complete — Logos is now fully configurable"
git push
```

---

## Self-review

1. **Spec coverage**: 10 tasks cover persistence + 2 new settings models + engine persistence + 6 tab views + window replacement + scene wiring + smoke + README. Maps to design § 7.9. ✅
2. **Placeholders**: None. Scope cuts (no custom regex rules, no hotkey customization) are explicit deferrals — clearly marked. ✅
3. **Type consistency**: `SettingsPersistence`, `GeneralSettings.Theme`, `AdvancedSettings.LogLevel`, `AutoHandleEngine.PersistedDTO` consistent. ✅
4. **Known risks**:
   - `TerminalConfig` changes don't fully live-apply to existing terminal sessions in v1 — font change requires re-creating SwiftTermView. Acceptable (most font tweaks are one-shot anyway); proper hot-reload deferred to vNext.
   - `.preferredColorScheme` may not affect every NSWindow (terminal panel's black background is hardcoded). Acceptable.
   - The Live preview tab edits raw YAML — no validation. If user breaks YAML, PDF builds fail silently. Mitigation: validate on save via `WorkspaceConfig.parse(yamlString:)`; show error inline if throws. **Add this hardening if smoke reveals it.**
   - Settings file format changes between Logos versions need migration. Defer formal migration; for v1 use `try?` so malformed JSON just resets to defaults.
   - `AdvancedSettings.claudePathOverride` interacts with `TerminalConfig.resolvedClaudePath` — two sources of truth. Workaround in T9 is fine but design-wise it's a smell. Refactor: make `TerminalConfig` take `AdvancedSettings` as a dependency. Defer this cleanup.
