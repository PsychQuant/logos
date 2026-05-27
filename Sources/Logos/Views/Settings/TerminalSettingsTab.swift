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
