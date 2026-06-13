import SwiftUI

/// Named dimensions for Logos's modal dialogs (#38), replacing scattered hardcoded
/// `.frame(width:height:)` literals across the Settings tabs + the account switcher.
/// One source of truth so dialog sizing stays consistent.
enum DialogSize {
    /// Standard settings tab (General / Terminal / Advanced).
    case settings
    /// Wider settings tab with more content (Live preview / Auto-handle).
    case wideSettings
    /// Accounts settings tab.
    case accounts
    /// The account switcher sheet.
    case switcher

    var size: CGSize {
        switch self {
        case .settings:     CGSize(width: 460, height: 320)
        case .wideSettings: CGSize(width: 540, height: 400)
        case .accounts:     CGSize(width: 480, height: 360)
        case .switcher:     CGSize(width: 380, height: 380)
        }
    }
}

extension View {
    /// Apply a named ``DialogSize`` as a fixed frame.
    func dialogFrame(_ dialog: DialogSize) -> some View {
        frame(width: dialog.size.width, height: dialog.size.height)
    }
}
