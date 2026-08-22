import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    init(root: URL) {
        self.root = root
        _selection = State(initialValue: root)
        _expandedDirectories = State(initialValue: Set([root]))
    }

    var body: some View {
        ExplorerSplitView {
            ExplorerTreePane(
                root: root,
                selection: $selection,
                expandedDirectories: $expandedDirectories,
                entriesByDirectory: entriesByDirectory,
                loadingDirectories: loadingDirectories,
                directoryErrors: directoryErrors,
                onLoadDirectory: requestLoad
            )
        } preview: {
            preview
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

private struct ExplorerSplitView<Tree: View, Preview: View>: View {
    @EnvironmentObject private var model: AppModel
    @GestureState private var treePaneDragOffset: CGFloat = 0

    let tree: Tree
    let preview: Preview

    private let minimumTreePaneWidth: CGFloat = 220
    private let maximumTreePaneWidth: CGFloat = 420
    private let minimumPreviewWidth: CGFloat = 400
    private let resizeHandleWidth: CGFloat = 8

    init(
        @ViewBuilder tree: () -> Tree,
        @ViewBuilder preview: () -> Preview
    ) {
        self.tree = tree()
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { geometry in
            let resolvedTreePaneWidth = clampedTreePaneWidth(
                model.fileExplorerTreePaneWidth + treePaneDragOffset,
                containerWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                tree
                    .frame(width: resolvedTreePaneWidth)
                    .frame(maxHeight: .infinity)
                resizeHandle(containerWidth: geometry.size.width)
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        }
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
                            model.fileExplorerTreePaneWidth + value.translation.width,
                            containerWidth: containerWidth
                        )
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            model.fileExplorerTreePaneWidth = proposedWidth
                        }
                    }
            )
            .help("Drag to resize the folder pane")
    }
}

private enum ExplorerChrome {
    static let folderBackground = Color.accentColor.opacity(0.08)
    static let branchPillFill = Color.primary.opacity(0.12)
}

private struct ExplorerBranchBar: View {
    let branch: String
    let branches: [String]
    let isBusy: Bool
    let onSelect: (String) -> Void

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .overlay {
                GeometryReader { geometry in
                    Menu {
                        ForEach(branches, id: \.self) { candidate in
                            Button {
                                onSelect(candidate)
                            } label: {
                                if candidate == branch {
                                    Label(candidate, systemImage: "checkmark")
                                } else {
                                    Text(candidate)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(branch.isEmpty ? "Loading branches…" : branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                        .background(ExplorerChrome.branchPillFill, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(branches.isEmpty || isBusy)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(ExplorerChrome.folderBackground)
            .accessibilityLabel("File explorer branch")
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
            ExplorerChrome.folderBackground

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
        }
        .buttonStyle(ResponsiveButtonStyle(
            isSelected: selection == url,
            shape: .rounded(5),
            selectedBackground: Color.accentColor.opacity(0.16)
        ))
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
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ResponsiveButtonStyle())
                    .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
                    .listRowBackground(Color.clear)
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
        if ExplorerFileType.isImage(url) { return "photo" }
        switch url.pathExtension.lowercased() {
        case "json", "yml", "yaml": return "curlybraces"
        default: return "doc"
        }
    }

    private var color: Color {
        if url.isDirectory { return .blue }
        return SourceLanguage(url: url) == .swift ? .orange : .accentColor
    }
}

enum FilePreviewPolicy {
    static let largeFileByteThreshold = 256 * 1_024
    static let largeFileLineThreshold = 5_000
    static let previewByteLimit = 100 * 1_024
    static let previewLineLimit = 2_000

    static func lineCount(in contents: String) -> Int {
        guard !contents.isEmpty else { return 0 }
        let newlineCount = contents.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return newlineCount + (contents.utf8.last == 0x0A ? 0 : 1)
    }

    static func limitedPreview(of contents: String) -> String {
        let lineLimited = contents
            .split(separator: "\n", maxSplits: previewLineLimit, omittingEmptySubsequences: false)
            .prefix(previewLineLimit)
            .joined(separator: "\n")
        var data = Data(lineLimited.utf8.prefix(previewByteLimit))
        while !data.isEmpty, String(data: data, encoding: .utf8) == nil {
            data.removeLast()
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct FilePreviewMetadata: Sendable, Equatable {
    let byteCount: Int64

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

struct FilePreviewReadResult: Sendable, Equatable {
    let contents: String
    let metadata: FilePreviewMetadata
    let totalLineCount: Int
    let displayedLineCount: Int
    let isTruncated: Bool

    var shouldHighlight: Bool {
        supportsRichPreview
    }

    var supportsRichPreview: Bool {
        !isTruncated
            && metadata.byteCount <= FilePreviewPolicy.largeFileByteThreshold
            && totalLineCount <= FilePreviewPolicy.largeFileLineThreshold
    }
}

private struct PreparedTextPreview: Sendable {
    let id = UUID()
    let readResult: FilePreviewReadResult
    let tokens: [SourceToken]?
}

private enum FilePreviewLoadMode: Hashable, Sendable {
    case automatic
    case full
}

private enum FilePreviewPhase {
    case reading(FilePreviewMetadata?)
    case preparing(FilePreviewMetadata)
    case loaded(PreparedTextPreview)
    case failed(String)
}

enum FilePreviewLoader {
    static func metadata(for url: URL) async throws -> FilePreviewMetadata {
        try await detached {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return FilePreviewMetadata(byteCount: Int64(values.fileSize ?? 0))
        }
    }

    static func read(
        url: URL,
        metadata: FilePreviewMetadata,
        loadFullFile: Bool
    ) async throws -> FilePreviewReadResult {
        try await detached {
            if !loadFullFile, metadata.byteCount > FilePreviewPolicy.largeFileByteThreshold {
                return try readLargePreview(url: url, metadata: metadata)
            }

            try Task.checkCancellation()
            let contents = try String(contentsOf: url, encoding: .utf8)
            try Task.checkCancellation()
            let totalLineCount = FilePreviewPolicy.lineCount(in: contents)
            let shouldLimit = !loadFullFile && totalLineCount > FilePreviewPolicy.largeFileLineThreshold
            let displayedContents = shouldLimit ? FilePreviewPolicy.limitedPreview(of: contents) : contents
            return FilePreviewReadResult(
                contents: displayedContents,
                metadata: metadata,
                totalLineCount: totalLineCount,
                displayedLineCount: FilePreviewPolicy.lineCount(in: displayedContents),
                isTruncated: shouldLimit
            )
        }
    }

    static func tokens(for contents: String, language: SourceLanguage) async throws -> [SourceToken] {
        try await detached {
            try Task.checkCancellation()
            let tokens = SourceSyntaxHighlighter.tokens(in: contents, as: language)
            try Task.checkCancellation()
            return tokens
        }
    }

    private static func readLargePreview(
        url: URL,
        metadata: FilePreviewMetadata
    ) throws -> FilePreviewReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var prefix = Data()
        prefix.reserveCapacity(FilePreviewPolicy.previewByteLimit)
        var newlineCount = 0
        var finalByte: UInt8?

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            newlineCount += chunk.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            }
            finalByte = chunk.last

            let remaining = FilePreviewPolicy.previewByteLimit - prefix.count
            if remaining > 0 {
                prefix.append(chunk.prefix(remaining))
            }
        }

        while !prefix.isEmpty, String(data: prefix, encoding: .utf8) == nil {
            prefix.removeLast()
        }
        guard let prefixContents = String(data: prefix, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let contents = FilePreviewPolicy.limitedPreview(of: prefixContents)
        let totalLineCount = metadata.byteCount == 0
            ? 0
            : newlineCount + (finalByte == 0x0A ? 0 : 1)
        return FilePreviewReadResult(
            contents: contents,
            metadata: metadata,
            totalLineCount: totalLineCount,
            displayedLineCount: FilePreviewPolicy.lineCount(in: contents),
            isTruncated: Int64(contents.utf8.count) < metadata.byteCount
                || totalLineCount > FilePreviewPolicy.previewLineLimit
        )
    }

    private static func detached<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private struct FilePreview: View {
    let url: URL
    let root: URL
    @State private var phase: FilePreviewPhase = .reading(nil)
    @State private var loadMode: FilePreviewLoadMode = .automatic

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: ExplorerFileType.isImage(url) ? "photo" : "doc.text")
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
                headerStatus
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(.bar)
            Divider()

            if ExplorerFileType.isImage(url) {
                LocalImagePreview(url: url)
            } else {
                previewBody
            }
        }
        .task(id: loadMode) {
            guard !ExplorerFileType.isImage(url) else { return }
            await loadPreview()
        }
    }

    @ViewBuilder
    private var headerStatus: some View {
        if ExplorerFileType.isImage(url) {
            fileTypeLabel("Image")
        } else {
            switch phase {
            case .reading(let metadata):
                fileTypeLabel(metadata?.formattedByteCount ?? "Reading…")
            case .preparing(let metadata):
                fileTypeLabel("Preparing • \(metadata.formattedByteCount)")
            case .loaded(let preview):
                fileTypeLabel("\(preview.readResult.totalLineCount.formatted()) lines • \(preview.readResult.metadata.formattedByteCount)")
            case .failed:
                fileTypeLabel(SourceLanguage(url: url)?.displayName ?? "Text")
            }
        }
    }

    private func fileTypeLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var previewBody: some View {
        switch phase {
        case .reading(let metadata):
            PaneLoadingView(
                metadata.map { "Reading \(url.lastPathComponent) • \($0.formattedByteCount)" }
                    ?? "Reading \(url.lastPathComponent)…"
            )
        case .preparing:
            PaneLoadingView("Preparing preview…")
        case .failed(let message):
            FilePreviewFeedback(message: message)
        case .loaded(let prepared):
            let result = prepared.readResult
            VStack(spacing: 0) {
                if result.isTruncated {
                    LargeFilePreviewBanner(
                        displayedLineCount: result.displayedLineCount,
                        totalLineCount: result.totalLineCount,
                        byteCount: result.metadata.formattedByteCount,
                        onLoadFullFile: { loadMode = .full },
                        onOpenExternally: { NSWorkspace.shared.open(url) }
                    )
                    Divider()
                }

                if MarkdownDocument.isMarkdownFile(url), result.supportsRichPreview {
                    MarkdownPreviewView(
                        markdown: result.contents,
                        baseURL: url.deletingLastPathComponent(),
                        maximumContentWidth: nil
                    )
                } else {
                    TextFilePreview(
                        id: prepared.id,
                        contents: result.contents,
                        tokens: prepared.tokens
                    )
                }
            }
        }
    }

    @MainActor
    private func loadPreview() async {
        phase = .reading(nil)
        do {
            let metadata = try await FilePreviewLoader.metadata(for: url)
            try Task.checkCancellation()
            phase = .reading(metadata)

            let readResult = try await FilePreviewLoader.read(
                url: url,
                metadata: metadata,
                loadFullFile: loadMode == .full
            )
            try Task.checkCancellation()
            phase = .preparing(metadata)

            let tokens: [SourceToken]?
            if readResult.shouldHighlight, let language = SourceLanguage(url: url) {
                tokens = try await FilePreviewLoader.tokens(for: readResult.contents, language: language)
            } else {
                tokens = nil
                await Task.yield()
            }
            try Task.checkCancellation()
            phase = .loaded(PreparedTextPreview(readResult: readResult, tokens: tokens))
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("This file isn’t UTF-8 text, or it can’t be read.")
        }
    }
}

private struct LargeFilePreviewBanner: View {
    let displayedLineCount: Int
    let totalLineCount: Int
    let byteCount: String
    let onLoadFullFile: () -> Void
    let onOpenExternally: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text("Showing the first \(displayedLineCount.formatted()) of \(totalLineCount.formatted()) lines (\(byteCount)).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button("Open in Default App", action: onOpenExternally)
            Button("Load Full File", action: onLoadFullFile)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
        .accessibilityElement(children: .contain)
    }
}

enum ExplorerFileType {
    static func isImage(_ url: URL) -> Bool {
        guard !url.pathExtension.isEmpty,
              let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }
}

private struct LocalImagePreview: View {
    let url: URL
    @State private var data: Data?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                ImagePreview(image: image)
            } else if let errorMessage {
                FilePreviewFeedback(message: errorMessage, systemImage: "photo.badge.exclamationmark")
            } else {
                PaneLoadingView("Loading image…")
            }
        }
        .task {
            do {
                data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                if data.flatMap(NSImage.init(data:)) == nil {
                    errorMessage = "This image format can’t be displayed."
                }
            } catch {
                errorMessage = "This image can’t be read."
            }
        }
    }
}

private struct ImagePreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(20)
            .accessibilityLabel("Image preview")
    }
}

private struct FilePreviewFeedback: View {
    let message: String
    var systemImage = "doc.badge.ellipsis"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Preview unavailable")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct TextFilePreview: NSViewRepresentable {
    let id: UUID
    let contents: String
    let tokens: [SourceToken]?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("File preview")
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard context.coordinator.renderedID != id,
              let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.renderedID = id
        textView.textStorage?.setAttributedString(attributedContents)
        textView.scrollToBeginningOfDocument(nil)
    }

    private var attributedContents: NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]

        guard let tokens else {
            return NSAttributedString(string: contents, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString()
        for token in tokens {
            var attributes = baseAttributes
            if let color = color(for: token.kind) {
                attributes[.foregroundColor] = color
            }
            result.append(NSAttributedString(string: token.text, attributes: attributes))
        }
        return result
    }

    private func color(for kind: SourceToken.Kind) -> NSColor? {
        switch kind {
        case .plain: nil
        case .keyword: .systemPurple
        case .string: .systemRed
        case .comment: .secondaryLabelColor
        case .number: .systemBlue
        }
    }

    final class Coordinator {
        var renderedID: UUID?
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
    @State private var branches: [String] = []
    @State private var selectedBranch: String
    @State private var loadingBranches = false

    init(repository: Repository) {
        self.repository = repository
        _selectedBranch = State(initialValue: repository.defaultBranch ?? "")
    }

    private var root: RemoteFileEntry {
        RemoteFileEntry(name: repository.name, path: "", kind: .directory, size: 0, webURL: repository.webURL)
    }

    var body: some View {
        ExplorerSplitView {
            VStack(spacing: 0) {
                ExplorerBranchBar(
                    branch: selectedBranch,
                    branches: branches,
                    isBusy: loadingBranches,
                    onSelect: selectBranch
                )
                Divider()
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
                .scrollContentBackground(.hidden)
                .background(.clear)
            }
            .background(ExplorerChrome.folderBackground)
        } preview: {
            remotePreview
        }
        .task {
            loadingBranches = true
            do {
                branches = try await model.remoteBranches(for: repository)
                if selectedBranch.isEmpty { selectedBranch = branches.first ?? "" }
            } catch {
                model.showError(error.localizedDescription, title: "Couldn’t load branches")
            }
            if !selectedBranch.isEmpty, !branches.contains(selectedBranch) {
                branches.insert(selectedBranch, at: 0)
            }
            loadingBranches = false
            await load(path: "")
        }
    }

    @ViewBuilder
    private var remotePreview: some View {
        if let selection, selection.kind == .file {
            RemoteFilePreview(repository: repository, entry: selection, reference: selectedBranch)
                .id("\(selectedBranch):\(selection.path)")
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

    private func selectBranch(_ branch: String) {
        guard branch != selectedBranch else { return }
        selectedBranch = branch
        selection = nil
        expanded = [""]
        entriesByPath = [:]
        loadingPaths = []
        errors = [:]
        requestLoad("")
    }

    @MainActor
    private func load(path: String) async {
        guard entriesByPath[path] == nil, !loadingPaths.contains(path), !model.token(for: repository).isEmpty else { return }
        loadingPaths.insert(path)
        errors[path] = nil
        do {
            entriesByPath[path] = try await model.remoteFiles(
                for: repository,
                path: path,
                reference: selectedBranch
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
                Image(systemName: remoteIcon)
                    .foregroundStyle(entry.kind == .directory ? Color.blue : Color.accentColor)
                    .frame(width: 18)
                Text(entry.name).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(ResponsiveButtonStyle(
            isSelected: selection == entry,
            shape: .rounded(5),
            selectedBackground: Color.accentColor.opacity(0.16)
        ))
    }

    private var remoteIcon: String {
        if isRoot { return "shippingbox.fill" }
        if entry.kind == .directory { return "folder.fill" }
        return ExplorerFileType.isImage(URL(fileURLWithPath: entry.path)) ? "photo" : "doc"
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
                        Image(systemName: remoteIcon(for: entry))
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsiveButtonStyle())
                .listRowInsets(EdgeInsets(top: 1, leading: 2, bottom: 1, trailing: 2))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.inset)
        }
    }

    private func remoteIcon(for entry: RemoteFileEntry) -> String {
        if entry.kind == .directory { return "folder.fill" }
        return ExplorerFileType.isImage(URL(fileURLWithPath: entry.path)) ? "photo" : "doc"
    }
}

private struct RemoteFilePreview: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    let entry: RemoteFileEntry
    let reference: String
    @State private var contents: String?
    @State private var sourceTokens: [SourceToken]?
    @State private var textPreviewID = UUID()
    @State private var imageData: Data?
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

            if let imageData, let image = NSImage(data: imageData) {
                ImagePreview(image: image)
            } else if let contents {
                if MarkdownDocument.isMarkdownFile(syntheticURL) {
                    MarkdownPreviewView(
                        markdown: contents,
                        baseURL: entry.webURL,
                        maximumContentWidth: nil
                    )
                } else {
                    TextFilePreview(
                        id: textPreviewID,
                        contents: contents,
                        tokens: sourceTokens
                    )
                }
            } else if let errorMessage {
                FilePreviewFeedback(
                    message: errorMessage,
                    systemImage: ExplorerFileType.isImage(syntheticURL)
                        ? "photo.badge.exclamationmark"
                        : "doc.badge.ellipsis"
                )
            } else {
                PaneLoadingView(ExplorerFileType.isImage(syntheticURL) ? "Loading image…" : "Loading preview…")
            }
        }
        .task {
            do {
                if ExplorerFileType.isImage(syntheticURL) {
                    let data = try await model.remoteFileData(
                        for: repository,
                        path: entry.path,
                        reference: reference
                    )
                    guard NSImage(data: data) != nil else {
                        errorMessage = "This image format can’t be displayed."
                        return
                    }
                    imageData = data
                } else {
                    let downloadedContents = try await model.remoteFileContents(
                        for: repository,
                        path: entry.path,
                        reference: reference
                    )
                    if !MarkdownDocument.isMarkdownFile(syntheticURL),
                       downloadedContents.utf8.count <= FilePreviewPolicy.largeFileByteThreshold,
                       FilePreviewPolicy.lineCount(in: downloadedContents) <= FilePreviewPolicy.largeFileLineThreshold,
                       let language = SourceLanguage(url: syntheticURL) {
                        sourceTokens = try await FilePreviewLoader.tokens(
                            for: downloadedContents,
                            language: language
                        )
                    }
                    try Task.checkCancellation()
                    contents = downloadedContents
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = ExplorerFileType.isImage(syntheticURL)
                    ? "This image can’t be downloaded."
                    : error.localizedDescription
            }
        }
    }
}
