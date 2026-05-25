import Foundation
import Observation

/// Storage abstraction over UserDefaults so models can be tested with
/// in-memory replacements without polluting real defaults between runs.
/// Plan adaptation #1.
@MainActor
public protocol LayoutDefaultsStorage {
    func object(forKey: String) -> Any?
    func set(_ value: Any?, forKey: String)
}

extension UserDefaults: LayoutDefaultsStorage {}

/// Persistent window pane layout state.
///
/// All values are stored via the injected storage so window restores its
/// layout between launches. Setters clamp to safe min/max ranges to prevent
/// invalid (e.g., 0-pixel) layouts on restore.
///
/// Implementation note: uses explicit computed properties with
/// `@ObservationIgnored` backing storage + manual `access`/`withMutation`
/// instead of stored property + didSet, because @Observable macro's
/// expansion of didSet that reassigns the same property causes infinite
/// recursion (despite Swift's "didSet not re-fired" language guarantee).
@Observable
@MainActor
public final class WindowLayoutState {

    public static let sidebarMinVisible: CGFloat = 40
    public static let sidebarMaxWidth: CGFloat = 500
    public static let sidebarDefaultWidth: CGFloat = 200

    public static let topAreaMinFraction: CGFloat = 0.2
    public static let topAreaMaxFraction: CGFloat = 0.8
    public static let topAreaDefaultFraction: CGFloat = 0.6

    public static let pdfPaneMinFraction: CGFloat = 0.2
    public static let pdfPaneMaxFraction: CGFloat = 0.8
    public static let pdfPaneDefaultFraction: CGFloat = 0.5

    @ObservationIgnored private let defaults: LayoutDefaultsStorage

    private enum Key {
        static let sidebarWidth = "logos.layout.sidebarWidth"
        static let topAreaFraction = "logos.layout.topAreaHeightFraction"
        static let pdfPaneFraction = "logos.layout.pdfPaneWidthFraction"
    }

    @ObservationIgnored private var _sidebarWidth: CGFloat = WindowLayoutState.sidebarDefaultWidth
    public var sidebarWidth: CGFloat {
        get {
            access(keyPath: \.sidebarWidth)
            return _sidebarWidth
        }
        set {
            withMutation(keyPath: \.sidebarWidth) {
                _sidebarWidth = min(max(newValue, 0), Self.sidebarMaxWidth)
                defaults.set(_sidebarWidth, forKey: Key.sidebarWidth)
            }
        }
    }

    @ObservationIgnored private var _topAreaHeightFraction: CGFloat = WindowLayoutState.topAreaDefaultFraction
    public var topAreaHeightFraction: CGFloat {
        get {
            access(keyPath: \.topAreaHeightFraction)
            return _topAreaHeightFraction
        }
        set {
            withMutation(keyPath: \.topAreaHeightFraction) {
                _topAreaHeightFraction = min(
                    max(newValue, Self.topAreaMinFraction),
                    Self.topAreaMaxFraction
                )
                defaults.set(_topAreaHeightFraction, forKey: Key.topAreaFraction)
            }
        }
    }

    @ObservationIgnored private var _pdfPaneWidthFraction: CGFloat = WindowLayoutState.pdfPaneDefaultFraction
    public var pdfPaneWidthFraction: CGFloat {
        get {
            access(keyPath: \.pdfPaneWidthFraction)
            return _pdfPaneWidthFraction
        }
        set {
            withMutation(keyPath: \.pdfPaneWidthFraction) {
                _pdfPaneWidthFraction = min(
                    max(newValue, Self.pdfPaneMinFraction),
                    Self.pdfPaneMaxFraction
                )
                defaults.set(_pdfPaneWidthFraction, forKey: Key.pdfPaneFraction)
            }
        }
    }

    public var isSidebarHidden: Bool {
        sidebarWidth < Self.sidebarMinVisible
    }

    public init(defaults: LayoutDefaultsStorage = UserDefaults.standard) {
        self.defaults = defaults

        if let stored = defaults.object(forKey: Key.sidebarWidth) as? CGFloat {
            self._sidebarWidth = stored
        }
        if let stored = defaults.object(forKey: Key.topAreaFraction) as? CGFloat {
            self._topAreaHeightFraction = stored
        }
        if let stored = defaults.object(forKey: Key.pdfPaneFraction) as? CGFloat {
            self._pdfPaneWidthFraction = stored
        }
    }
}
