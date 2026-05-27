import SwiftUI

struct PDFLiveRenderView: View {
    @Environment(PDFLivePreviewModel.self) private var model
    @Environment(WorkspaceModel.self) private var workspace

    var body: some View {
        ZStack {
            switch model.state {
            case .idle(let reason):
                PDFEmptyStateView(reason: reason)
            case .building(let cmd):
                buildingOverlay(commandPreview: cmd)
            case .success(let url, let builtAt):
                PDFViewerNSView(url: url, builtAt: builtAt)
            case .failure(let stderr):
                PDFBuildErrorBanner(stderrTail: stderr)
            }
        }
        .onChange(of: workspace.activeTab) { (_: OpenFileTab?, newTab: OpenFileTab?) in
            if let path = newTab?.path {
                let cfg = workspace.rootNode.flatMap { try? WorkspaceConfig.load(workspaceRoot: $0.path) }
                model.bind(sourcePath: path, config: cfg)
            } else {
                model.unbind()
            }
        }
    }

    private func buildingOverlay(commandPreview: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Building…")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(commandPreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
