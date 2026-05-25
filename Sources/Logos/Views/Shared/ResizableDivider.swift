import SwiftUI
import AppKit

/// A vertical or horizontal divider that updates a binding on drag.
/// - axis: .vertical for sidebar/editor splits (drag horizontal),
///         .horizontal for top/bottom (drag vertical).
struct ResizableDivider: View {
    enum Axis { case vertical, horizontal }
    let axis: Axis
    let onDrag: (CGFloat) -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
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
