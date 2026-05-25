# App Shell Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launchable empty Logos macOS app shell with VS Code-like layout (activity bar + sidebar + main area top/bottom + status bar). NO `claude` subprocess yet — terminal pane is a placeholder. NO real file/PDF content — placeholders. Window state persists. Resizable panes work. All shell wiring in place for later sub-plans to fill.

**Architecture:** SwiftUI-first macOS 15 app. SwiftPM executable target (Xcode-project migration deferred to packaging sub-plan). Models separated from views (Observation framework `@Observable`) so state logic is testable in isolation. Pane sizes persist via `@AppStorage`. Swift Testing for model tests. Manual visual verification for view layout (snapshot tests deferred).

**Tech Stack:** Swift 6, SwiftUI, SwiftPM, Swift Testing, macOS 15.0 SDK, Observation framework

**Resolved design decisions (from spec § 10):**
- Min macOS: 15 (Sequoia)
- License: MIT
- Bundle ID: `app.getlogos.logos`
- Activity bar: kept (Files / Search / Sessions / Settings / Account icons)
- Status bar items: all four (Account, Cost, Auto-handle status, Token usage)

**What this sub-plan does NOT include** (each is its own future sub-plan):
- Forked SwiftTerm integration → sub-plan B
- Renderer rewrite → sub-plan C
- Auto-handle pattern parser / decision engine → sub-plan D
- Multi-account / Keychain → sub-plan E
- Real file tree contents → sub-plan F
- Syntax highlighting → sub-plan F
- PDF rendering pipeline → sub-plan G
- Settings UI body → sub-plan H

---

## File Structure

```
logos/
├── Package.swift                                          NEW — SwiftPM manifest
├── Sources/
│   └── Logos/                                             NEW — main module
│       ├── App/
│       │   ├── LogosApp.swift                             NEW — @main entry
│       │   └── MainScene.swift                            NEW — WindowGroup config
│       ├── Models/
│       │   ├── WindowLayoutState.swift                    NEW — pane sizes, visibility, @Observable
│       │   ├── ActivityBarSelection.swift                 NEW — active tab enum + state
│       │   └── StatusBarViewModel.swift                   NEW — all 4 status items
│       ├── Views/
│       │   ├── MainView.swift                             NEW — top-level composition
│       │   ├── ActivityBar/
│       │   │   ├── ActivityBarView.swift                  NEW — left icon column
│       │   │   └── ActivityBarIcon.swift                  NEW — single icon button
│       │   ├── Sidebar/
│       │   │   └── SidebarView.swift                      NEW — switches by activity bar selection
│       │   ├── MainArea/
│       │   │   ├── MainAreaView.swift                     NEW — VStack: top + bottom
│       │   │   ├── TopPanesView.swift                     NEW — HStack: editor + PDF
│       │   │   ├── EditorPanePlaceholder.swift            NEW — placeholder text + icon
│       │   │   ├── PDFPanePlaceholder.swift               NEW — placeholder text + icon
│       │   │   └── TerminalPanePlaceholder.swift          NEW — placeholder text + icon
│       │   ├── StatusBar/
│       │   │   ├── StatusBarView.swift                    NEW — HStack of 4 items
│       │   │   ├── AccountStatusItem.swift                NEW
│       │   │   ├── CostStatusItem.swift                   NEW
│       │   │   ├── AutoHandleStatusItem.swift             NEW
│       │   │   └── TokenUsageStatusItem.swift             NEW
│       │   └── Settings/
│       │       └── SettingsWindow.swift                   NEW — empty Settings scene
│       └── Resources/
│           └── Info.plist                                 NEW — bundle ID, version
├── Tests/
│   └── LogosTests/
│       ├── WindowLayoutStateTests.swift                   NEW
│       ├── ActivityBarSelectionTests.swift                NEW
│       └── StatusBarViewModelTests.swift                  NEW
├── LICENSE                                                ALREADY UPDATED (MIT, 2026-05-25)
└── README.md                                              UPDATE — note shell foundation status
```

**Design principle:** Each file does one thing. Models (3 files) hold all state logic — testable. Views are thin renderers reading from models. Status bar items are 4 separate views so each can be developed/tested independently in future sub-plans.

---

## Task 1: Initialize SwiftPM project + Info.plist

**Files:**
- Create: `/Users/che/Developer/logos/Package.swift`
- Create: `/Users/che/Developer/logos/Sources/Logos/Resources/Info.plist`

- [ ] **Step 1: Create `Package.swift`**

Write:

```swift
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
            name: "Logos",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "LogosTests",
            dependencies: ["Logos"]
        )
    ]
)
```

- [ ] **Step 2: Create `Info.plist`** at `Sources/Logos/Resources/Info.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>app.getlogos.logos</string>
    <key>CFBundleName</key>
    <string>Logos</string>
    <key>CFBundleDisplayName</key>
    <string>Logos</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Che Cheng. MIT License.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 3: Verify project initializes**

Run: `swift build`
Expected: build fails with "no source files" — Package.swift is valid, just no Swift source yet. That's expected; the next task adds source.

- [ ] **Step 4: Commit**

```bash
cd /Users/che/Developer/logos
git add Package.swift Sources/Logos/Resources/Info.plist
git commit -m "feat(shell): initialize SwiftPM package for macOS 15 executable

Bundle ID app.getlogos.logos. Resources directory for Info.plist."
```

---

## Task 2: WindowLayoutState model + tests

**Files:**
- Create: `Sources/Logos/Models/WindowLayoutState.swift`
- Test: `Tests/LogosTests/WindowLayoutStateTests.swift`

**Purpose:** Track pane sizes (sidebar width, top-area height, PDF pane width within top area) and visibility (sidebar hidden when dragged to 0). All persisted to UserDefaults via `@AppStorage` so window restores layout on next launch.

- [ ] **Step 1: Write failing test**

Create `Tests/LogosTests/WindowLayoutStateTests.swift`:

```swift
import Testing
@testable import Logos

@Suite("WindowLayoutState")
@MainActor
struct WindowLayoutStateTests {

    @Test("default sidebar width is 200")
    func defaultSidebarWidth() {
        let state = WindowLayoutState()
        #expect(state.sidebarWidth == 200)
    }

    @Test("sidebar hidden when width below threshold")
    func sidebarHiddenBelowThreshold() {
        let state = WindowLayoutState()
        state.sidebarWidth = 30  // below 40 threshold
        #expect(state.isSidebarHidden == true)
    }

    @Test("sidebar visible when width above threshold")
    func sidebarVisibleAboveThreshold() {
        let state = WindowLayoutState()
        state.sidebarWidth = 100
        #expect(state.isSidebarHidden == false)
    }

    @Test("default top area height fraction is 0.6")
    func defaultTopAreaHeightFraction() {
        let state = WindowLayoutState()
        #expect(state.topAreaHeightFraction == 0.6)
    }

    @Test("default PDF pane width fraction is 0.5 (split top area in half)")
    func defaultPDFPaneWidthFraction() {
        let state = WindowLayoutState()
        #expect(state.pdfPaneWidthFraction == 0.5)
    }

    @Test("clamping: sidebar cannot exceed max")
    func sidebarClampMax() {
        let state = WindowLayoutState()
        state.sidebarWidth = 5000
        #expect(state.sidebarWidth <= 500)  // max
    }

    @Test("clamping: top area fraction stays in 0.2 ... 0.8")
    func topAreaFractionClamp() {
        let state = WindowLayoutState()
        state.topAreaHeightFraction = 0.05
        #expect(state.topAreaHeightFraction >= 0.2)
        state.topAreaHeightFraction = 0.95
        #expect(state.topAreaHeightFraction <= 0.8)
    }
}
```

- [ ] **Step 2: Run test — verify fails**

Run: `swift test`
Expected: FAIL — `WindowLayoutState` not defined.

- [ ] **Step 3: Implement minimal `WindowLayoutState`**

Create `Sources/Logos/Models/WindowLayoutState.swift`:

```swift
import Foundation
import Observation

/// Persistent window pane layout state.
///
/// All values are stored in UserDefaults so window restores its layout
/// between launches. Setters clamp to safe min/max ranges to prevent
/// invalid (e.g., 0-pixel) layouts on restore.
@Observable
@MainActor
final class WindowLayoutState {

    static let sidebarMinVisible: CGFloat = 40
    static let sidebarMaxWidth: CGFloat = 500
    static let sidebarDefaultWidth: CGFloat = 200

    static let topAreaMinFraction: CGFloat = 0.2
    static let topAreaMaxFraction: CGFloat = 0.8
    static let topAreaDefaultFraction: CGFloat = 0.6

    static let pdfPaneMinFraction: CGFloat = 0.2
    static let pdfPaneMaxFraction: CGFloat = 0.8
    static let pdfPaneDefaultFraction: CGFloat = 0.5

    private let defaults = UserDefaults.standard
    private enum Key {
        static let sidebarWidth = "logos.layout.sidebarWidth"
        static let topAreaFraction = "logos.layout.topAreaHeightFraction"
        static let pdfPaneFraction = "logos.layout.pdfPaneWidthFraction"
    }

    var sidebarWidth: CGFloat {
        didSet {
            sidebarWidth = min(max(sidebarWidth, 0), Self.sidebarMaxWidth)
            defaults.set(sidebarWidth, forKey: Key.sidebarWidth)
        }
    }

    var topAreaHeightFraction: CGFloat {
        didSet {
            topAreaHeightFraction = min(max(topAreaHeightFraction, Self.topAreaMinFraction), Self.topAreaMaxFraction)
            defaults.set(topAreaHeightFraction, forKey: Key.topAreaFraction)
        }
    }

    var pdfPaneWidthFraction: CGFloat {
        didSet {
            pdfPaneWidthFraction = min(max(pdfPaneWidthFraction, Self.pdfPaneMinFraction), Self.pdfPaneMaxFraction)
            defaults.set(pdfPaneWidthFraction, forKey: Key.pdfPaneFraction)
        }
    }

    var isSidebarHidden: Bool {
        sidebarWidth < Self.sidebarMinVisible
    }

    init() {
        let stored = defaults.object(forKey: Key.sidebarWidth) as? CGFloat
        self.sidebarWidth = stored ?? Self.sidebarDefaultWidth

        let storedTop = defaults.object(forKey: Key.topAreaFraction) as? CGFloat
        self.topAreaHeightFraction = storedTop ?? Self.topAreaDefaultFraction

        let storedPDF = defaults.object(forKey: Key.pdfPaneFraction) as? CGFloat
        self.pdfPaneWidthFraction = storedPDF ?? Self.pdfPaneDefaultFraction
    }
}
```

- [ ] **Step 4: Run test — verify all pass**

Run: `swift test --filter WindowLayoutStateTests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Models/WindowLayoutState.swift Tests/LogosTests/WindowLayoutStateTests.swift
git commit -m "feat(shell): WindowLayoutState model with pane sizes + persistence

Sidebar / top-area / PDF-pane fractions persist via UserDefaults.
All setters clamp to safe ranges. 7 tests cover defaults + clamping + hide."
```

---

## Task 3: ActivityBarSelection model + tests

**Files:**
- Create: `Sources/Logos/Models/ActivityBarSelection.swift`
- Test: `Tests/LogosTests/ActivityBarSelectionTests.swift`

**Purpose:** Track which activity bar tab is active (Files / Search / Sessions / Settings / Account). Toggle behavior: clicking the active tab hides the sidebar; clicking a different tab switches.

- [ ] **Step 1: Write failing test**

Create `Tests/LogosTests/ActivityBarSelectionTests.swift`:

```swift
import Testing
@testable import Logos

@Suite("ActivityBarSelection")
@MainActor
struct ActivityBarSelectionTests {

    @Test("default selection is files")
    func defaultIsFiles() {
        let s = ActivityBarSelection()
        #expect(s.active == .files)
        #expect(s.isVisible == true)
    }

    @Test("clicking different tab switches selection and stays visible")
    func switchTab() {
        let s = ActivityBarSelection()
        s.select(.search)
        #expect(s.active == .search)
        #expect(s.isVisible == true)
    }

    @Test("clicking active tab toggles visibility off")
    func toggleHide() {
        let s = ActivityBarSelection()
        s.select(.files)  // already files
        #expect(s.isVisible == false)
    }

    @Test("clicking active tab again toggles visibility on")
    func toggleShow() {
        let s = ActivityBarSelection()
        s.select(.files)  // hides
        s.select(.files)  // shows again
        #expect(s.isVisible == true)
    }

    @Test("five tabs defined")
    func tabCount() {
        #expect(ActivityBarSelection.Tab.allCases.count == 5)
    }
}
```

- [ ] **Step 2: Run test — verify fails**

Run: `swift test --filter ActivityBarSelectionTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement**

Create `Sources/Logos/Models/ActivityBarSelection.swift`:

```swift
import Foundation
import Observation

/// Activity bar tab selection + sidebar visibility.
///
/// Click semantics:
///   - Click inactive tab → switch to it, sidebar becomes visible
///   - Click active tab → toggle sidebar visibility
@Observable
@MainActor
final class ActivityBarSelection {

    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case files
        case search
        case sessions
        case settings
        case account

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .files: "folder"
            case .search: "magnifyingglass"
            case .sessions: "rectangle.stack"
            case .settings: "gearshape"
            case .account: "person.crop.circle"
            }
        }

        var label: String {
            switch self {
            case .files: "Files"
            case .search: "Search"
            case .sessions: "Sessions"
            case .settings: "Settings"
            case .account: "Account"
            }
        }
    }

    private(set) var active: Tab = .files
    private(set) var isVisible: Bool = true

    func select(_ tab: Tab) {
        if tab == active {
            isVisible.toggle()
        } else {
            active = tab
            isVisible = true
        }
    }
}
```

- [ ] **Step 4: Run test — verify pass**

Run: `swift test --filter ActivityBarSelectionTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Models/ActivityBarSelection.swift Tests/LogosTests/ActivityBarSelectionTests.swift
git commit -m "feat(shell): ActivityBarSelection with toggle-hide semantics

5 tabs (files/search/sessions/settings/account) with SF Symbol mapping.
Click active tab to hide sidebar; click again to show."
```

---

## Task 4: StatusBarViewModel + tests

**Files:**
- Create: `Sources/Logos/Models/StatusBarViewModel.swift`
- Test: `Tests/LogosTests/StatusBarViewModelTests.swift`

**Purpose:** Hold the 4 status bar items' display state. In sub-plan A all values are static placeholders ("personal", "$0.00", `.armed`, "0 / 200k"). Future sub-plans (D auto-handle, E multi-account) will wire real data in.

- [ ] **Step 1: Write failing test**

Create `Tests/LogosTests/StatusBarViewModelTests.swift`:

```swift
import Testing
@testable import Logos

@Suite("StatusBarViewModel")
@MainActor
struct StatusBarViewModelTests {

    @Test("default account name is placeholder")
    func defaultAccount() {
        let vm = StatusBarViewModel()
        #expect(vm.accountName == "personal")
    }

    @Test("default cost is zero formatted")
    func defaultCost() {
        let vm = StatusBarViewModel()
        #expect(vm.sessionCostFormatted == "$0.00")
    }

    @Test("default auto-handle is armed")
    func defaultAutoHandle() {
        let vm = StatusBarViewModel()
        #expect(vm.autoHandleStatus == .armed)
    }

    @Test("token usage formats with k suffix")
    func tokenFormat() {
        let vm = StatusBarViewModel()
        vm.tokensUsed = 12_345
        vm.tokensMax = 200_000
        #expect(vm.tokenUsageFormatted == "12k / 200k")
    }

    @Test("zero tokens still formats correctly")
    func zeroTokensFormat() {
        let vm = StatusBarViewModel()
        #expect(vm.tokenUsageFormatted == "0 / 200k")
    }

    @Test("auto-handle status has three cases")
    func autoHandleCases() {
        #expect(StatusBarViewModel.AutoHandleStatus.allCases.count == 3)
    }
}
```

- [ ] **Step 2: Run test — verify fails**

Run: `swift test --filter StatusBarViewModelTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement**

Create `Sources/Logos/Models/StatusBarViewModel.swift`:

```swift
import Foundation
import Observation
import SwiftUI

/// Status bar display state. Placeholders in sub-plan A;
/// future sub-plans wire real data:
///   - accountName ← sub-plan E (multi-account)
///   - sessionCost ← sub-plan D parsing claude output
///   - autoHandleStatus ← sub-plan D auto-handle decision engine
///   - tokensUsed / tokensMax ← sub-plan D parsing claude output
@Observable
@MainActor
final class StatusBarViewModel {

    enum AutoHandleStatus: String, CaseIterable, Sendable {
        case armed
        case partial
        case disabled

        var label: String {
            switch self {
            case .armed: "auto-handle: armed"
            case .partial: "auto-handle: partial"
            case .disabled: "auto-handle: disabled"
            }
        }

        var color: Color {
            switch self {
            case .armed: .green
            case .partial: .yellow
            case .disabled: .red
            }
        }
    }

    var accountName: String = "personal"
    var sessionCostUSD: Decimal = 0
    var autoHandleStatus: AutoHandleStatus = .armed
    var tokensUsed: Int = 0
    var tokensMax: Int = 200_000

    var sessionCostFormatted: String {
        String(format: "$%.2f", NSDecimalNumber(decimal: sessionCostUSD).doubleValue)
    }

    var tokenUsageFormatted: String {
        "\(formatK(tokensUsed)) / \(formatK(tokensMax))"
    }

    private func formatK(_ n: Int) -> String {
        if n < 1_000 { return "\(n)" }
        let k = n / 1_000
        return "\(k)k"
    }
}
```

- [ ] **Step 4: Run test — verify pass**

Run: `swift test --filter StatusBarViewModelTests`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Logos/Models/StatusBarViewModel.swift Tests/LogosTests/StatusBarViewModelTests.swift
git commit -m "feat(shell): StatusBarViewModel with 4-item placeholder state

Account name, formatted USD cost, auto-handle status (armed/partial/disabled
with color), token usage with k-suffix formatting.
Real data wired in sub-plans D + E."
```

---

## Task 5: App entry point + window scene

**Files:**
- Create: `Sources/Logos/App/LogosApp.swift`
- Create: `Sources/Logos/App/MainScene.swift`

**Purpose:** `@main` annotation. WindowGroup with one window. Settings scene stub so `⌘,` does nothing weird. Window has min/max constraints. State models injected as `@State` (held by the scene).

- [ ] **Step 1: Create `LogosApp.swift`**

```swift
import SwiftUI

@main
struct LogosApp: App {
    var body: some Scene {
        MainScene()

        // Settings scene added in Task 10 once SettingsWindow exists.
    }
}
```

- [ ] **Step 2: Create `MainScene.swift`**

```swift
import SwiftUI

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 3: Verify build still fails (MainView undefined yet)**

Run: `swift build`
Expected: FAIL — `MainView` not defined yet. Expected — added in Task 6.

- [ ] **Step 4: Commit (intentionally incomplete state — partial commit allowed since infrastructure scaffolding)**

```bash
git add Sources/Logos/App/
git commit -m "feat(shell): app entry point + window scene scaffolding

LogosApp @main with MainScene WindowGroup + Settings stub. State models
injected via Environment (Observation). Window 900x600 min, 1400x900 ideal.
Build intentionally broken until views land in next tasks."
```

---

## Task 6: MainView composition (with placeholder children)

**Files:**
- Create: `Sources/Logos/Views/MainView.swift`
- Create: `Sources/Logos/Views/Sidebar/SidebarView.swift`
- Create: `Sources/Logos/Views/MainArea/MainAreaView.swift`
- Create: `Sources/Logos/Views/MainArea/TopPanesView.swift`
- Create: `Sources/Logos/Views/MainArea/EditorPanePlaceholder.swift`
- Create: `Sources/Logos/Views/MainArea/PDFPanePlaceholder.swift`
- Create: `Sources/Logos/Views/MainArea/TerminalPanePlaceholder.swift`

**Purpose:** Skeleton of overall layout. Each view is a placeholder showing where future content goes. Activity bar is in Task 7. Status bar is in Task 8. After this task `swift build` succeeds and `swift run` launches a window — but resize handles don't yet do anything fancy (Task 9).

- [ ] **Step 1: Create `MainView.swift`**

```swift
import SwiftUI

struct MainView: View {

    @Environment(WindowLayoutState.self) private var layout
    @Environment(ActivityBarSelection.self) private var activityBar
    @Environment(StatusBarViewModel.self) private var statusBar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ActivityBarView()

                if activityBar.isVisible && !layout.isSidebarHidden {
                    SidebarView()
                        .frame(width: layout.sidebarWidth)
                    Divider()
                }

                MainAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            Divider()
            StatusBarView()
        }
    }
}
```

- [ ] **Step 2: Create `SidebarView.swift`**

```swift
import SwiftUI

struct SidebarView: View {

    @Environment(ActivityBarSelection.self) private var activityBar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(activityBar.active.label.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Text("Placeholder — content loaded in sub-plan F (Files), D (Sessions), H (Settings), E (Account)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor))
    }
}
```

- [ ] **Step 3: Create `MainAreaView.swift`**

```swift
import SwiftUI

struct MainAreaView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                TopPanesView()
                    .frame(height: geo.size.height * layout.topAreaHeightFraction)

                Divider()

                TerminalPanePlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
```

- [ ] **Step 4: Create `TopPanesView.swift`**

```swift
import SwiftUI

struct TopPanesView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                EditorPanePlaceholder()
                    .frame(width: geo.size.width * (1 - layout.pdfPaneWidthFraction))

                Divider()

                PDFPanePlaceholder()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
```

- [ ] **Step 5: Create three placeholder views**

`EditorPanePlaceholder.swift`:

```swift
import SwiftUI

struct EditorPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Editor / file viewer")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Content loaded in sub-plan F")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
```

`PDFPanePlaceholder.swift`:

```swift
import SwiftUI

struct PDFPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("PDF live render")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Content loaded in sub-plan G")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
```

`TerminalPanePlaceholder.swift`:

```swift
import SwiftUI

struct TerminalPanePlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "apple.terminal")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Terminal — Claude Code")
                .font(.headline)
                .foregroundStyle(Color.green.opacity(0.8))
            Text("SwiftTerm integration in sub-plan B → renderer in sub-plan C")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
```

- [ ] **Step 6: Build — verify still fails (ActivityBarView + StatusBarView + SettingsWindow missing)**

Run: `swift build`
Expected: FAIL on `ActivityBarView`, `StatusBarView`, `SettingsWindow` — added in next tasks.

- [ ] **Step 7: Commit**

```bash
git add Sources/Logos/Views/MainView.swift Sources/Logos/Views/Sidebar/ Sources/Logos/Views/MainArea/
git commit -m "feat(shell): MainView composition + 5 placeholder pane views

Layout: ActivityBar | Sidebar | (Editor | PDF) / Terminal | StatusBar.
Each pane is a placeholder pointing to its future sub-plan. Build still
broken until activity bar + status bar + settings stub land."
```

---

## Task 7: ActivityBar implementation

**Files:**
- Create: `Sources/Logos/Views/ActivityBar/ActivityBarView.swift`
- Create: `Sources/Logos/Views/ActivityBar/ActivityBarIcon.swift`

**Purpose:** 36px-wide left icon column. 5 icons (one per Tab). Active tab visually highlighted. Click triggers `select()` on the selection model.

- [ ] **Step 1: Create `ActivityBarIcon.swift`**

```swift
import SwiftUI

struct ActivityBarIcon: View {

    let tab: ActivityBarSelection.Tab
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Rectangle()
                        .fill(isActive ? Color.accentColor.opacity(0.15) : .clear)
                )
                .overlay(alignment: .leading) {
                    if isActive {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
    }
}
```

- [ ] **Step 2: Create `ActivityBarView.swift`**

```swift
import SwiftUI

struct ActivityBarView: View {

    @Environment(ActivityBarSelection.self) private var selection

    var body: some View {
        VStack(spacing: 0) {
            // Files / Search / Sessions go top
            ForEach([ActivityBarSelection.Tab.files,
                     .search,
                     .sessions], id: \.self) { tab in
                ActivityBarIcon(
                    tab: tab,
                    isActive: selection.active == tab && selection.isVisible,
                    action: { selection.select(tab) }
                )
            }

            Spacer()

            // Settings / Account pinned bottom
            ForEach([ActivityBarSelection.Tab.settings,
                     .account], id: \.self) { tab in
                ActivityBarIcon(
                    tab: tab,
                    isActive: selection.active == tab && selection.isVisible,
                    action: { selection.select(tab) }
                )
            }
        }
        .frame(width: 36)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Views/ActivityBar/
git commit -m "feat(shell): ActivityBarView 36px column with 5 SF Symbol icons

Top: Files / Search / Sessions. Bottom: Settings / Account.
Active state shows accent background + 2px leading bar.
Tab click delegates to ActivityBarSelection.select()."
```

---

## Task 8: StatusBar implementation

**Files:**
- Create: `Sources/Logos/Views/StatusBar/StatusBarView.swift`
- Create: `Sources/Logos/Views/StatusBar/AccountStatusItem.swift`
- Create: `Sources/Logos/Views/StatusBar/CostStatusItem.swift`
- Create: `Sources/Logos/Views/StatusBar/AutoHandleStatusItem.swift`
- Create: `Sources/Logos/Views/StatusBar/TokenUsageStatusItem.swift`

**Purpose:** 24px-tall strip at window bottom. 4 items left-aligned, plus a spacer. Each item is its own view (so sub-plans D + E can swap implementations later).

- [ ] **Step 1: Create 4 status items**

`AccountStatusItem.swift`:

```swift
import SwiftUI

struct AccountStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.accountName, systemImage: "person.crop.circle")
            .font(.caption)
            .help("Click to switch account (sub-plan E)")
    }
}
```

`CostStatusItem.swift`:

```swift
import SwiftUI

struct CostStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.sessionCostFormatted, systemImage: "dollarsign.circle")
            .font(.caption)
            .help("Session running cost (wired in sub-plan D)")
    }
}
```

`AutoHandleStatusItem.swift`:

```swift
import SwiftUI

struct AutoHandleStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.autoHandleStatus.label, systemImage: "bolt.fill")
            .font(.caption)
            .foregroundStyle(vm.autoHandleStatus.color)
            .help("Auto-handle pattern engine status (wired in sub-plan D)")
    }
}
```

`TokenUsageStatusItem.swift`:

```swift
import SwiftUI

struct TokenUsageStatusItem: View {
    @Environment(StatusBarViewModel.self) private var vm

    var body: some View {
        Label(vm.tokenUsageFormatted, systemImage: "chart.bar")
            .font(.caption)
            .help("Context window tokens used / max (wired in sub-plan D)")
    }
}
```

- [ ] **Step 2: Create `StatusBarView.swift`**

```swift
import SwiftUI

struct StatusBarView: View {
    var body: some View {
        HStack(spacing: 12) {
            AccountStatusItem()
            CostStatusItem()
            AutoHandleStatusItem()
            TokenUsageStatusItem()
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sources/Logos/Views/StatusBar/
git commit -m "feat(shell): StatusBarView with 4 items + per-item placeholder views

24px strip. Account / cost / auto-handle status (colored) / token usage.
Each item is its own view so sub-plans D + E can swap implementations
without touching StatusBarView composition."
```

---

## Task 9: Resize behavior + persistence

**Files:**
- Modify: `Sources/Logos/Views/MainView.swift`
- Modify: `Sources/Logos/Views/MainArea/MainAreaView.swift`
- Modify: `Sources/Logos/Views/MainArea/TopPanesView.swift`

**Purpose:** Add `Divider` drag-handles between sidebar/main, top-area/terminal, editor/PDF. Drag updates `WindowLayoutState`. Persistence comes free via `@AppStorage` in the model.

- [ ] **Step 1: Add drag-resizable divider helper**

Create new file `Sources/Logos/Views/Shared/ResizableDivider.swift`:

```swift
import SwiftUI

/// A vertical or horizontal divider that updates a binding on drag.
/// - axis: .vertical for sidebar/editor splits (drag horizontal), .horizontal for top/bottom (drag vertical).
struct ResizableDivider: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let onDrag: (CGFloat) -> Void

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.001))   // invisible hit area
            .frame(
                width: axis == .vertical ? 6 : nil,
                height: axis == .horizontal ? 6 : nil
            )
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(
                        width: axis == .vertical ? 1 : nil,
                        height: axis == .horizontal ? 1 : nil
                    )
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    if axis == .vertical {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.resizeUpDown.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let delta = axis == .vertical
                            ? value.translation.width
                            : value.translation.height
                        onDrag(delta)
                    }
            )
    }
}
```

- [ ] **Step 2: Update `MainView.swift` to use ResizableDivider for sidebar**

Replace the body of `MainView` with:

```swift
var body: some View {
    @Bindable var layout = layout

    VStack(spacing: 0) {
        HStack(spacing: 0) {
            ActivityBarView()

            if activityBar.isVisible && !layout.isSidebarHidden {
                SidebarView()
                    .frame(width: layout.sidebarWidth)

                ResizableDivider(axis: .vertical) { delta in
                    layout.sidebarWidth = max(0, layout.sidebarWidth + delta)
                }
            }

            MainAreaView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)

        Divider()
        StatusBarView()
    }
}
```

(The `@Bindable` line above is required because `MainView` reads but doesn't own the `@Observable` model — we need `@Bindable` to derive write access.)

- [ ] **Step 3: Update `MainAreaView.swift` for vertical resize between top + bottom**

```swift
import SwiftUI

struct MainAreaView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        @Bindable var layout = layout

        GeometryReader { geo in
            VStack(spacing: 0) {
                TopPanesView()
                    .frame(height: geo.size.height * layout.topAreaHeightFraction)

                ResizableDivider(axis: .horizontal) { delta in
                    let newFraction = layout.topAreaHeightFraction + (delta / geo.size.height)
                    layout.topAreaHeightFraction = newFraction
                }

                TerminalPanePlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
```

- [ ] **Step 4: Update `TopPanesView.swift` for horizontal resize editor↔PDF**

```swift
import SwiftUI

struct TopPanesView: View {

    @Environment(WindowLayoutState.self) private var layout

    var body: some View {
        @Bindable var layout = layout

        GeometryReader { geo in
            HStack(spacing: 0) {
                EditorPanePlaceholder()
                    .frame(width: geo.size.width * (1 - layout.pdfPaneWidthFraction))

                ResizableDivider(axis: .vertical) { delta in
                    // dragging right shrinks PDF pane; convert delta into PDF fraction delta
                    let newPDFFraction = layout.pdfPaneWidthFraction - (delta / geo.size.width)
                    layout.pdfPaneWidthFraction = newPDFFraction
                }

                PDFPanePlaceholder()
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
```

- [ ] **Step 5: Build — verify compiles**

Run: `swift build`
Expected: SUCCESS — all referenced types exist (Task 5 deferred Settings scene to Task 10, so no missing symbols).

- [ ] **Step 6: Launch sanity check (optional)**

Run: `swift run`
Expected: window opens with placeholders + status bar; resize handles work; ⌘, does nothing (Settings scene not yet attached).

- [ ] **Step 7: Commit**

```bash
git add Sources/Logos/Views/Shared/ResizableDivider.swift Sources/Logos/Views/MainView.swift Sources/Logos/Views/MainArea/
git commit -m "feat(shell): drag-resizable dividers between all panes

ResizableDivider helper with hover cursor + drag gesture for both axes.
Sidebar / top-bottom / editor-PDF all resize. Persistence comes free
via WindowLayoutState UserDefaults setters."
```

---

## Task 10: Settings window stub

**Files:**
- Create: `Sources/Logos/Views/Settings/SettingsWindow.swift`

**Purpose:** ⌘, opens an empty Settings window with tab placeholders. Tab body is just "Settings UI in sub-plan H" text. SwiftUI's `Settings` scene gives us the standard Mac Preferences window for free.

- [ ] **Step 1: Create `SettingsWindow.swift`** at `Sources/Logos/Views/Settings/SettingsWindow.swift`

```swift
import SwiftUI

struct SettingsWindow: View {

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case terminal = "Terminal"
        case autoHandle = "Auto-handle"
        case accounts = "Accounts"
        case livePreview = "Live preview"
        case advanced = "Advanced"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: "gear"
            case .terminal: "apple.terminal"
            case .autoHandle: "bolt"
            case .accounts: "person.2"
            case .livePreview: "doc.richtext"
            case .advanced: "wrench.adjustable"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(Tab.allCases) { tab in
                VStack {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text(tab.rawValue)
                        .font(.title2)
                    Text("Settings UI in sub-plan H")
                        .foregroundStyle(.secondary)
                }
                .frame(width: 480, height: 320)
                .tabItem {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
                .tag(tab)
            }
        }
        .frame(width: 480, height: 360)
    }
}
```

- [ ] **Step 2: Attach Settings scene to `LogosApp.swift`**

Modify `Sources/Logos/App/LogosApp.swift`:

```swift
import SwiftUI

@main
struct LogosApp: App {
    var body: some Scene {
        MainScene()

        Settings {
            SettingsWindow()
        }
    }
}
```

- [ ] **Step 3: Build — verify everything compiles**

Run: `swift build`
Expected: SUCCESS — all symbols resolved.

- [ ] **Step 4: Commit**

```bash
git add Sources/Logos/Views/Settings/ Sources/Logos/App/LogosApp.swift
git commit -m "feat(shell): Settings window stub with 6 tab placeholders

⌘, opens Settings scene. Tabs: General / Terminal / Auto-handle /
Accounts / Live preview / Advanced. Each tab body is placeholder
pointing to sub-plan H for real content."
```

---

## Task 11: Final visual pass + README update

**Files:**
- Modify: `/Users/che/Developer/logos/README.md`

**Purpose:** Run the app, verify everything works visually, take a screenshot, update README to reflect that sub-plan A is complete.

- [ ] **Step 1: Launch the app**

Run: `swift run`
Expected: A Logos window opens. Verify visually:
- Window title is "Logos"
- Activity bar visible on left (36px, 5 icons, top 3 + spacer + bottom 2)
- Sidebar visible (200px) showing "FILES" label
- Editor placeholder (left half of top area)
- PDF placeholder (right half of top area)
- Terminal placeholder (bottom area, black background)
- Status bar at very bottom showing all 4 items
- Window resizes to min 900×600

- [ ] **Step 2: Manual interaction smoke tests**

Verify each:
- [ ] Click Search icon → sidebar shows "SEARCH" label
- [ ] Click Search again → sidebar hides
- [ ] Click Files → sidebar shows "FILES"
- [ ] Drag the divider between sidebar and main area → sidebar resizes
- [ ] Drag sidebar to width < 40 → sidebar hides automatically
- [ ] Drag horizontal divider between top area and terminal → ratio changes
- [ ] Drag vertical divider between editor and PDF → ratio changes
- [ ] Press ⌘, → Settings window opens with 6 tabs
- [ ] Close & relaunch with `swift run` → pane sizes persist (UserDefaults)

If any check fails, identify which task introduced the issue, revisit, fix, recommit, re-run smoke tests.

- [ ] **Step 3: Take screenshot**

Run: `screencapture -i ~/Desktop/logos-shell-v0.1.png`

Save to project as proof of milestone:
```bash
mkdir -p docs/screenshots
mv ~/Desktop/logos-shell-v0.1.png docs/screenshots/shell-foundation.png
```

- [ ] **Step 4: Update README**

Edit `/Users/che/Developer/logos/README.md`. Replace the `## Repo status` section with:

```markdown
## Repo status

**Sub-plan A (App shell foundation) — COMPLETE** ✅
- Window layout shell launchable via `swift run`
- All panes are placeholders pointing to future sub-plans
- Resize + persistence working
- Screenshot: [`docs/screenshots/shell-foundation.png`](docs/screenshots/shell-foundation.png)

**Next**: sub-plan B (SwiftTerm integration + claude subprocess)

Design doc: [`docs/design/2026-05-25-logos-design.md`](docs/design/2026-05-25-logos-design.md)
All sub-plans: [`docs/superpowers/plans/`](docs/superpowers/plans/)
```

- [ ] **Step 5: Final commit**

```bash
git add docs/screenshots/shell-foundation.png README.md
git commit -m "docs(shell): screenshot + README update marking sub-plan A complete

Sub-plan A delivered: launchable shell with activity bar, sidebar,
top-bottom main area split, status bar, settings stub, drag resize,
persistence. All visual smoke tests pass. Ready for sub-plan B."
```

- [ ] **Step 6: Run all tests one final time**

Run: `swift test`
Expected: all 18 tests pass (7 WindowLayoutState + 5 ActivityBarSelection + 6 StatusBarViewModel).

---

## Done. Next steps:

After sub-plan A completion:
1. Update design doc to mark sub-plan A delivered (add to § 14 roadmap progress)
2. Open next plan in `docs/superpowers/plans/2026-XX-XX-swiftterm-integration.md` (sub-plan B)
3. Sub-plan B will: add `swift-term` package dependency (the fork), replace `TerminalPanePlaceholder` with real SwiftTerm view rendering a `claude` subprocess, add minimal PTY hosting, smoke-test against `claude` running in the pane (tearing acceptable at this point — that's sub-plan C's job)
