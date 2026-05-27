import SwiftUI

struct EditorPaneView: View {
    @Environment(WorkspaceModel.self) private var workspace
    @State private var contentCache: [String: Result<String, FileContentLoader.Error>] = [:]
    private let loader = FileContentLoader()

    var body: some View {
        VStack(spacing: 0) {
            FileTabBar()
            Divider()

            if let tab = workspace.activeTab {
                viewer(for: tab)
                    .id(tab.path)
            } else {
                EmptyEditorPlaceholder()
            }
        }
    }

    @ViewBuilder
    private func viewer(for tab: OpenFileTab) -> some View {
        let result = loadContent(for: tab)
        switch result {
        case .success(let content):
            switch (tab.path as NSString).pathExtension.lowercased() {
            case "md", "markdown":
                MarkdownViewer(content: content)
            case "swift", "py", "rb", "js", "ts", "go", "rs", "c", "cpp", "h", "hpp",
                 "java", "kt", "json", "yaml", "yml", "toml", "sh", "bash", "html",
                 "css", "scss", "tex", "r", "lua", "sql":
                CodeViewer(content: content, language: (tab.path as NSString).pathExtension.lowercased())
            default:
                PlainTextViewer(content: content)
            }
        case .failure(let err):
            if case .tooLarge(let actual, let max) = err {
                FileTooLargeBanner(path: tab.path, actualBytes: actual, maxBytes: max)
            } else {
                ErrorBanner(error: err)
            }
        }
    }

    private func loadContent(for tab: OpenFileTab) -> Result<String, FileContentLoader.Error> {
        if let cached = contentCache[tab.path] {
            return cached
        }
        let result: Result<String, FileContentLoader.Error>
        do {
            result = .success(try loader.load(path: tab.path))
        } catch let err as FileContentLoader.Error {
            result = .failure(err)
        } catch {
            result = .failure(.notUtf8)
        }
        contentCache[tab.path] = result
        return result
    }
}

private struct EmptyEditorPlaceholder: View {
    var body: some View {
        VStack {
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No file open")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Click a file in the sidebar to view it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

private struct ErrorBanner: View {
    let error: FileContentLoader.Error

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(.yellow)
            Text("Cannot preview this file")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        switch error {
        case .notUtf8: "Binary file (not valid UTF-8)"
        case .tooLarge(let a, let m): "Exceeds size cap (\(a) > \(m) bytes)"
        }
    }
}
