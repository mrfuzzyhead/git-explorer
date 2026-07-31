import SwiftUI

struct FileBrowserView: View {
    let repository: Repository

    var body: some View {
        if let root = repository.localURL?.standardizedFileURL {
            FileExplorerWorkspace(root: root)
                .id(root)
        } else {
            ContentUnavailableView(
                "Repository unavailable",
                systemImage: "folder.badge.questionmark"
            )
        }
    }
}

private struct FileExplorerWorkspace: View {
    @EnvironmentObject private var model: AppModel

    let root: URL
    @State private var selection: URL
    @State private var expandedDirectories: Set<URL> = []
    @State private var entriesByDirectory: [URL: [URL]] = [:]
    @State private var loadingDirectories: Set<URL> = []
    @State private var directoryErrors: [URL: String] = [:]

    init(root: URL) {
        self.root = root
        _selection = State(initialValue: root)
        _expandedDirectories = State(initialValue: Set([root]))
    }

    var body: some View {
        HSplitView {
            ExplorerTreePane(
                root: root,
                selection: $selection,
                expandedDirectories: $expandedDirectories,
                entriesByDirectory: entriesByDirectory,
                loadingDirectories: loadingDirectories,
                directoryErrors: directoryErrors,
                onLoadDirectory: requestLoad
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            preview
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await loadDirectoryIfNeeded(root)
        }
        .task(id: selection) {
            guard selection.isDirectory else { return }
            await loadDirectoryIfNeeded(selection)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if selection.isDirectory {
            FolderPreview(
                directory: selection,
                root: root,
                entries: entriesByDirectory[selection],
                isLoading: loadingDirectories.contains(selection),
                error: directoryErrors[selection],
                onSelect: select
            )
            .id(selection)
        } else {
            FilePreview(url: selection, root: root)
                .id(selection)
        }
    }

    private func select(_ item: URL) {
        guard ExplorerPath.contains(item, in: root) else { return }
        selection = item.standardizedFileURL
    }

    @MainActor
    private func requestLoad(_ directory: URL) {
        Task { await loadDirectoryIfNeeded(directory) }
    }

    @MainActor
    private func loadDirectoryIfNeeded(_ directory: URL) async {
        let directory = directory.standardizedFileURL
        guard ExplorerPath.contains(directory, in: root),
              entriesByDirectory[directory] == nil,
              !loadingDirectories.contains(directory) else { return }

        loadingDirectories.insert(directory)
        directoryErrors[directory] = nil
        do {
            entriesByDirectory[directory] = try await model.git.listFiles(at: directory)
        } catch {
            directoryErrors[directory] = error.localizedDescription
            model.errorMessage = error.localizedDescription
        }
        loadingDirectories.remove(directory)
    }
}

private struct ExplorerTreePane: View {
    let root: URL
    @Binding var selection: URL
    @Binding var expandedDirectories: Set<URL>
    let entriesByDirectory: [URL: [URL]]
    let loadingDirectories: Set<URL>
    let directoryErrors: [URL: String]
    let onLoadDirectory: (URL) -> Void

    var body: some View {
        List {
            ExplorerTreeNode(
                url: root,
                selection: $selection,
                expandedDirectories: $expandedDirectories,
                entriesByDirectory: entriesByDirectory,
                loadingDirectories: loadingDirectories,
                directoryErrors: directoryErrors,
                onLoadDirectory: onLoadDirectory,
                isRepositoryRoot: true
            )
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Files and folders in \(root.lastPathComponent)")
    }
}

private struct ExplorerTreeNode: View {
    let url: URL
    @Binding var selection: URL
    @Binding var expandedDirectories: Set<URL>
    let entriesByDirectory: [URL: [URL]]
    let loadingDirectories: Set<URL>
    let directoryErrors: [URL: String]
    let onLoadDirectory: (URL) -> Void
    var isRepositoryRoot = false

    @ViewBuilder
    var body: some View {
        if url.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                if loadingDirectories.contains(url) && entriesByDirectory[url] == nil {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 24)
                } else if directoryErrors[url] != nil {
                    Label("Unable to load folder", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entriesByDirectory[url] ?? [], id: \.self) { child in
                        ExplorerTreeNode(
                            url: child,
                            selection: $selection,
                            expandedDirectories: $expandedDirectories,
                            entriesByDirectory: entriesByDirectory,
                            loadingDirectories: loadingDirectories,
                            directoryErrors: directoryErrors,
                            onLoadDirectory: onLoadDirectory
                        )
                    }
                }
            } label: {
                selectableLabel
            }
        } else {
            selectableLabel
        }
    }

    private var selectableLabel: some View {
        Button {
            selection = url
        } label: {
            HStack(spacing: 8) {
                if isRepositoryRoot {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                } else {
                    FileItemIcon(url: url)
                }
                Text(url.lastPathComponent)
                    .fontWeight(isRepositoryRoot ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background {
                if selection == url {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
        }
        .buttonStyle(.plain)
        .help(isRepositoryRoot ? "Show repository contents" : url.isDirectory ? "Show folder contents" : "Preview file")
    }

    private var expansionBinding: Binding<Bool> {
        Binding {
            expandedDirectories.contains(url)
        } set: { isExpanded in
            if isExpanded {
                expandedDirectories.insert(url)
                onLoadDirectory(url)
            } else {
                expandedDirectories.remove(url)
            }
        }
    }
}

private struct FolderPreview: View {
    let directory: URL
    let root: URL
    let entries: [URL]?
    let isLoading: Bool
    let error: String?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(directory.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(ExplorerPath.relativePath(of: directory, from: root))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let entries {
                    Text(entries.count == 1 ? "1 item" : "\(entries.count) items")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.bar)
            Divider()

            if isLoading && entries == nil {
                ProgressView("Loading folder…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView(
                    "Couldn’t open folder",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if entries?.isEmpty == true {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            } else {
                List(entries ?? [], id: \.self) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        HStack(spacing: 10) {
                            FileItemIcon(url: entry)
                            Text(entry.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            if entry.isDirectory {
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.isDirectory ? "Show folder contents" : "Preview file")
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct FileItemIcon: View {
    let url: URL

    var body: some View {
        Image(systemName: icon)
            .foregroundStyle(color)
            .frame(width: 18)
    }

    private var icon: String {
        if url.isDirectory { return "folder.fill" }
        if MarkdownDocument.isMarkdownFile(url) { return "doc.richtext" }
        if SourceLanguage(url: url) != nil { return "chevron.left.forwardslash.chevron.right" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "json", "yml", "yaml": return "curlybraces"
        default: return "doc"
        }
    }

    private var color: Color {
        if url.isDirectory { return .blue }
        return SourceLanguage(url: url) == .swift ? .orange : .accentColor
    }
}

private struct FilePreview: View {
    let url: URL
    let root: URL
    @State private var contents: String?
    @State private var readError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                    Text(ExplorerPath.relativePath(of: url, from: root))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if let language = SourceLanguage(url: url) {
                    Text(language.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if MarkdownDocument.isMarkdownFile(url) {
                    Text("Markdown")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.bar)
            Divider()

            if let contents {
                preview(contents)
            } else if let readError {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(readError)
                )
            } else {
                ProgressView("Loading preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            do {
                contents = try String(contentsOf: url, encoding: .utf8)
            } catch {
                readError = "This file isn’t UTF-8 text, or it can’t be read."
            }
        }
    }

    @ViewBuilder
    private func preview(_ contents: String) -> some View {
        if MarkdownDocument.isMarkdownFile(url) {
            MarkdownPreviewView(markdown: contents, baseURL: url.deletingLastPathComponent())
        } else {
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Group {
                        if let language = SourceLanguage(url: url) {
                            Text(SourceSyntaxHighlighter.highlight(contents, as: language))
                        } else {
                            Text(contents)
                        }
                    }
                    .font(.system(.callout, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(16)
                    .frame(
                        minWidth: geometry.size.width,
                        minHeight: geometry.size.height,
                        alignment: .topLeading
                    )
                }
            }
        }
    }
}

enum ExplorerPath {
    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func crumbs(from root: URL, to directory: URL) -> [URL] {
        guard contains(directory, in: root) else { return [root] }
        let rootComponents = root.standardizedFileURL.pathComponents
        let childComponents = directory.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
        return childComponents.reduce(into: [root.standardizedFileURL]) { result, component in
            result.append(result.last!.appendingPathComponent(component, isDirectory: true))
        }
    }

    static func relativePath(of url: URL, from root: URL) -> String {
        guard contains(url, in: root) else { return url.path }
        if url.standardizedFileURL == root.standardizedFileURL {
            return root.lastPathComponent
        }
        let components = url.standardizedFileURL.pathComponents
            .dropFirst(root.standardizedFileURL.pathComponents.count)
        return components.joined(separator: "/")
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
