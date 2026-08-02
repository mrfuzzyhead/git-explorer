import SwiftUI

struct FileBrowserView: View {
    let repository: Repository

    var body: some View {
        if let root = repository.localURL?.standardizedFileURL {
            FileExplorerWorkspace(root: root)
                .id(root)
        } else {
            RemoteFileExplorerWorkspace(repository: repository)
                .id(repository.id)
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
    @State private var treePaneWidth: CGFloat
    @GestureState private var treePaneDragOffset: CGFloat = 0

    private static let treePaneWidthDefaultsKey = "fileExplorer.treePaneWidth"
    private static let defaultTreePaneWidth: CGFloat = 280
    private let minimumTreePaneWidth: CGFloat = 220
    private let maximumTreePaneWidth: CGFloat = 420
    private let minimumPreviewWidth: CGFloat = 400
    private let resizeHandleWidth: CGFloat = 8

    init(root: URL) {
        self.root = root
        _selection = State(initialValue: root)
        _expandedDirectories = State(initialValue: Set([root]))
        _treePaneWidth = State(initialValue: Self.savedTreePaneWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedTreePaneWidth = clampedTreePaneWidth(
                treePaneWidth + treePaneDragOffset,
                containerWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                ExplorerTreePane(
                    root: root,
                    selection: $selection,
                    expandedDirectories: $expandedDirectories,
                    entriesByDirectory: entriesByDirectory,
                    loadingDirectories: loadingDirectories,
                    directoryErrors: directoryErrors,
                    onLoadDirectory: requestLoad
                )
                .frame(width: resolvedTreePaneWidth)

                resizeHandle(containerWidth: geometry.size.width)

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
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
        let item = item.standardizedFileURL
        selection = item

        guard item.isDirectory else { return }
        let directories = ExplorerPath.crumbs(from: root, to: item)
        expandedDirectories.formUnion(directories)
        directories.forEach(requestLoad)
    }

    private func clampedTreePaneWidth(_ proposedWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let availableMaximum = max(
            minimumTreePaneWidth,
            containerWidth - minimumPreviewWidth - resizeHandleWidth
        )
        return min(max(proposedWidth, minimumTreePaneWidth), min(maximumTreePaneWidth, availableMaximum))
    }

    private func resizeHandle(containerWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: resizeHandleWidth)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($treePaneDragOffset) { value, offset, transaction in
                        transaction.animation = nil
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        let proposedWidth = clampedTreePaneWidth(
                            treePaneWidth + value.translation.width,
                            containerWidth: containerWidth
                        )
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            treePaneWidth = proposedWidth
                        }
                        UserDefaults.standard.set(
                            Double(treePaneWidth),
                            forKey: Self.treePaneWidthDefaultsKey
                        )
                    }
            )
            .help("Drag to resize the folder pane")
    }

    private static var savedTreePaneWidth: CGFloat {
        guard UserDefaults.standard.object(forKey: treePaneWidthDefaultsKey) != nil else {
            return defaultTreePaneWidth
        }
        return CGFloat(UserDefaults.standard.double(forKey: treePaneWidthDefaultsKey))
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
            model.showError(error.localizedDescription, title: "Couldn’t load files")
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
        ZStack {
            Color.accentColor.opacity(0.08)

            ScrollViewReader { proxy in
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
                .scrollContentBackground(.hidden)
                .background(.clear)
                .onChange(of: selection) { _, selection in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(selection, anchor: .center)
                    }
                }
                .overlay {
                    if loadingDirectories.contains(root), entriesByDirectory[root] == nil {
                        PaneLoadingView("Loading files…")
                            .background(.regularMaterial)
                    }
                }
            }
        }
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
        .id(url)
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
    let entries: [URL]?
    let isLoading: Bool
    let error: String?
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if isLoading && entries == nil {
                PaneLoadingView("Loading folder…")
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
                    .listRowSeparator(.hidden)
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
                PaneLoadingView("Loading preview…")
            }
        }
        .task {
            do {
                contents = try await Task.detached(priority: .userInitiated) {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
            } catch {
                readError = "This file isn’t UTF-8 text, or it can’t be read."
            }
        }
    }

    @ViewBuilder
    private func preview(_ contents: String) -> some View {
        if MarkdownDocument.isMarkdownFile(url) {
            MarkdownPreviewView(
                markdown: contents,
                baseURL: url.deletingLastPathComponent(),
                maximumContentWidth: nil
            )
        } else {
            TextFilePreview(contents: contents, url: url)
        }
    }
}

private struct TextFilePreview: View {
    let contents: String
    let url: URL

    var body: some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct RemoteFileExplorerWorkspace: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository

    @State private var selection: RemoteFileEntry?
    @State private var expanded: Set<String> = [""]
    @State private var entriesByPath: [String: [RemoteFileEntry]] = [:]
    @State private var loadingPaths: Set<String> = []
    @State private var errors: [String: String] = [:]

    private var root: RemoteFileEntry {
        RemoteFileEntry(name: repository.name, path: "", kind: .directory, size: 0, webURL: repository.webURL)
    }

    var body: some View {
        HSplitView {
            List {
                RemoteFileTreeNode(
                    entry: root,
                    selection: $selection,
                    expanded: $expanded,
                    entriesByPath: entriesByPath,
                    loadingPaths: loadingPaths,
                    errors: errors,
                    onLoad: requestLoad,
                    isRoot: true
                )
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 420)

            remotePreview
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await load(path: "") }
    }

    @ViewBuilder
    private var remotePreview: some View {
        if let selection, selection.kind == .file {
            RemoteFilePreview(repository: repository, entry: selection)
                .id(selection.path)
        } else {
            let directory = selection?.path ?? ""
            RemoteFolderPreview(
                entries: entriesByPath[directory],
                isLoading: loadingPaths.contains(directory),
                error: errors[directory],
                onSelect: { entry in
                    selection = entry
                    if entry.kind == .directory {
                        expanded.insert(entry.path)
                        requestLoad(entry.path)
                    }
                }
            )
        }
    }

    private func requestLoad(_ path: String) {
        Task { await load(path: path) }
    }

    @MainActor
    private func load(path: String) async {
        guard entriesByPath[path] == nil, !loadingPaths.contains(path), !model.githubToken.isEmpty else { return }
        loadingPaths.insert(path)
        errors[path] = nil
        do {
            entriesByPath[path] = try await model.github.files(
                fullName: repository.fullName,
                path: path,
                reference: repository.defaultBranch,
                token: model.githubToken
            )
        } catch {
            errors[path] = error.localizedDescription
            model.showError(error.localizedDescription, title: "Couldn’t load files")
        }
        loadingPaths.remove(path)
    }
}

private struct RemoteFileTreeNode: View {
    let entry: RemoteFileEntry
    @Binding var selection: RemoteFileEntry?
    @Binding var expanded: Set<String>
    let entriesByPath: [String: [RemoteFileEntry]]
    let loadingPaths: Set<String>
    let errors: [String: String]
    let onLoad: (String) -> Void
    var isRoot = false

    @ViewBuilder
    var body: some View {
        if entry.kind == .directory {
            DisclosureGroup(isExpanded: expansion) {
                if loadingPaths.contains(entry.path), entriesByPath[entry.path] == nil {
                    ProgressView().controlSize(.small).padding(.leading, 20)
                } else if errors[entry.path] != nil {
                    Label("Unable to load folder", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                } else {
                    ForEach(entriesByPath[entry.path] ?? []) { child in
                        RemoteFileTreeNode(
                            entry: child,
                            selection: $selection,
                            expanded: $expanded,
                            entriesByPath: entriesByPath,
                            loadingPaths: loadingPaths,
                            errors: errors,
                            onLoad: onLoad
                        )
                    }
                }
            } label: { label }
        } else {
            label
        }
    }

    private var label: some View {
        Button { selection = entry } label: {
            HStack(spacing: 8) {
                Image(systemName: isRoot ? "shippingbox.fill" : entry.kind == .directory ? "folder.fill" : "doc")
                    .foregroundStyle(entry.kind == .directory ? Color.blue : Color.accentColor)
                    .frame(width: 18)
                Text(entry.name).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expansion: Binding<Bool> {
        Binding {
            expanded.contains(entry.path)
        } set: { value in
            if value {
                expanded.insert(entry.path)
                onLoad(entry.path)
            } else {
                expanded.remove(entry.path)
            }
        }
    }
}

private struct RemoteFolderPreview: View {
    let entries: [RemoteFileEntry]?
    let isLoading: Bool
    let error: String?
    let onSelect: (RemoteFileEntry) -> Void

    var body: some View {
        if isLoading && entries == nil {
            PaneLoadingView("Loading folder…")
        } else if let error {
            ContentUnavailableView("Couldn’t open folder", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if entries?.isEmpty == true {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        } else {
            List(entries ?? []) { entry in
                Button { onSelect(entry) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.kind == .directory ? "folder.fill" : "doc")
                            .foregroundStyle(entry.kind == .directory ? Color.blue : Color.accentColor)
                            .frame(width: 18)
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        if entry.kind == .directory {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
        }
    }
}

private struct RemoteFilePreview: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    let entry: RemoteFileEntry
    @State private var contents: String?
    @State private var errorMessage: String?

    private var syntheticURL: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let webURL = entry.webURL {
                    Link("Open on GitHub", destination: webURL)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.bar)
            Divider()

            if let contents {
                if MarkdownDocument.isMarkdownFile(syntheticURL) {
                    MarkdownPreviewView(
                        markdown: contents,
                        baseURL: entry.webURL,
                        maximumContentWidth: nil
                    )
                } else {
                    TextFilePreview(contents: contents, url: syntheticURL)
                }
            } else if let errorMessage {
                ContentUnavailableView("Preview unavailable", systemImage: "doc.badge.ellipsis", description: Text(errorMessage))
            } else {
                PaneLoadingView("Loading preview…")
            }
        }
        .task {
            do {
                contents = try await model.github.fileContents(
                    fullName: repository.fullName,
                    path: entry.path,
                    reference: repository.defaultBranch,
                    token: model.githubToken
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
