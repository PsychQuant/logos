import SwiftUI

extension View {
    /// Shared chrome for transient notification **banners** (#38): uniform padding +
    /// a material fill clipped to a rounded rectangle. Dedupes the two banner sites
    /// — `TerminalPaneView`'s AuthNeededBanner and `MainView`'s errorBanner — which
    /// previously hand-rolled the same `material + RoundedRectangle(cornerRadius:)`.
    ///
    /// Captures the banner's *intrinsic* chrome only; **positioning** padding (where
    /// the banner sits in its parent) stays at the call site. `material` is a param
    /// because the two banners differ (`.regularMaterial` vs `.thinMaterial`) — the
    /// param preserves each look while sharing the shape.
    ///
    /// Not for the larger centered overlays (e.g. the loading panel uses radius 12 /
    /// padding 24) — those are deliberately bigger and stay inline.
    func bannerStyle(material: Material = .regularMaterial, cornerRadius: CGFloat = 8) -> some View {
        self
            .padding(10)
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}
