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
