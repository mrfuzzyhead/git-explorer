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
    @State private var directory: URL
    @State private var folders: [URL] = []
    @State private var files: [URL] = []
    @State private var selectedFile: URL?
    @State private var isLoading = true
    @State private var loadError: String?

    init(root: URL) {
        self.root = root
        _directory = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                crumbs: ExplorerPath.crumbs(from: root, to: directory),
                selectedDirectory: directory,
                onSelect: navigate
            )
            Divider()
            HSplitView {
                FolderPane(
                    directory: directory,
                    folders: folders,
                    isLoading: isLoading,
                    onOpen: navigate
                )
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 320)

                FilePane(
                    files: files,
                    selection: $selectedFile,
                    isLoading: isLoading
                )
                .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

                preview
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: directory) {
            await load(directory)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let selectedFile {
            FilePreview(url: selectedFile, root: root)
                .id(selectedFile)
        } else if let loadError {
            ContentUnavailableView(
                "Couldn’t open folder",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
        } else {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a file to preview its contents.")
            )
        }
    }

    private func navigate(to destination: URL) {
        guard ExplorerPath.contains(destination, in: root) else { return }
        directory = destination.standardizedFileURL
        selectedFile = nil
    }

    @MainActor
    private func load(_ requestedDirectory: URL) async {
        isLoading = true
        loadError = nil
        do {
            let entries = try await model.git.listFiles(at: requestedDirectory)
            guard directory == requestedDirectory else { return }
            folders = entries.filter(\.isDirectory)
            files = entries.filter { !$0.isDirectory }
            if let selectedFile, !files.contains(selectedFile) {
                self.selectedFile = nil
            }
        } catch {
            guard directory == requestedDirectory else { return }
            folders = []
            files = []
            selectedFile = nil
            loadError = error.localizedDescription
            model.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct BreadcrumbBar: View {
    let crumbs: [URL]
    let selectedDirectory: URL
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        onSelect(crumb)
                    } label: {
                        Label {
                            Text(crumb.lastPathComponent)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: index == 0 ? "shippingbox.fill" : "folder.fill")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(crumb == selectedDirectory ? .primary : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background {
                        if crumb == selectedDirectory {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .help("Open \(crumb.path)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

private struct FolderPane: View {
    let directory: URL
    let folders: [URL]
    let isLoading: Bool
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Folders", count: folders.count)
            Divider()
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if folders.isEmpty {
                ContentUnavailableView("No folders", systemImage: "folder")
            } else {
                List(folders, id: \.self) { folder in
                    Button {
                        onOpen(folder)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(folder.lastPathComponent)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(folder.lastPathComponent)")
                }
                .listStyle(.sidebar)
            }
        }
        .accessibilityLabel("Folders in \(directory.lastPathComponent)")
    }
}

private struct FilePane: View {
    let files: [URL]
    @Binding var selection: URL?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Files", count: files.count)
            Divider()
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView("No files", systemImage: "doc")
            } else {
                List(files, id: \.self, selection: $selection) { file in
                    FileRow(url: file)
                        .tag(file)
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct PaneHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

private struct FileRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                if !url.pathExtension.isEmpty {
                    Text(url.pathExtension.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        if MarkdownDocument.isMarkdownFile(url) { return "doc.richtext" }
        if SourceLanguage(url: url) != nil { return "chevron.left.forwardslash.chevron.right" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "json", "yml", "yaml": return "curlybraces"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        SourceLanguage(url: url) == .swift ? .orange : .accentColor
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
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
