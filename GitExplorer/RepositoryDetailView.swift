import SwiftUI

struct RepositoryDetailView: View {
    let repository: Repository

    var body: some View {
        if repository.isLocal {
            LocalRepositoryView(repository: repository)
        } else {
            RemoteRepositoryView(repository: repository)
        }
    }
}

private struct RemoteRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    @State private var readme: String?
    @State private var loading = true
    @State private var selection = RemoteTab.graph

    private enum RemoteTab: String, CaseIterable, Identifiable {
        case readme = "Readme"
        case graph = "Graph"
        case files = "Files"
        case actions = "Actions"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            RepositoryHeader(repository: repository)
            Divider()
            RepositoryViewBar(selection: $selection, tabs: RemoteTab.allCases) {
                Button {
                    Task { await model.clone(repository) }
                } label: {
                    Label("Clone", systemImage: "arrow.down.to.line")
                        .frame(height: 20, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .disabled(model.cloningRepositoryIDs.contains(repository.id))
            }
            Divider()
            Group {
                switch selection {
                case .readme:
                    if loading {
                        PaneLoadingView("Loading README…")
                    } else if let readme {
                        MarkdownPreviewView(markdown: readme, baseURL: repository.webURL)
                    } else {
                        ContentUnavailableView(
                            "No README",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text("This repository does not contain a README.")
                        )
                    }
                case .graph:
                    CommitGraphView(repository: repository)
                case .files:
                    FileBrowserView(repository: repository)
                case .actions:
                    RepositoryActionsView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            defer { loading = false }
            guard !model.githubToken.isEmpty else { return }
            do {
                readme = try await model.github.readme(fullName: repository.fullName, token: model.githubToken)
            } catch {
                model.showError(error.localizedDescription, title: "Couldn’t load README")
            }
        }
    }

}

private struct LocalRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    @State private var selection = LocalTab.graph
    @State private var statusState = LocalRepositoryStatusState.loading
    @State private var operation: RepositoryOperation?
    @State private var graphReloadToken = 0

    enum LocalTab: String, CaseIterable, Identifiable {
        case readme = "Readme"
        case graph = "Graph"
        case files = "Files"
        case actions = "Actions"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            RepositoryHeader(
                repository: repository,
                localStatusState: statusState
            )
            Divider()
            RepositoryViewBar(selection: $selection, tabs: LocalTab.allCases) {
                ForEach([RepositoryOperation.fetch, .pull, .push, .sync], id: \.rawValue) { item in
                    Button { perform(item) } label: {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(operation != nil)
                    .help(help(for: item))
                }
                if operation != nil {
                    ProgressView().controlSize(.small)
                }
            }
            Divider()
            Group {
                switch selection {
                case .readme: LocalReadmeView(repository: repository)
                case .graph:
                    CommitGraphView(repository: repository, reloadToken: graphReloadToken) { status in
                        statusState = .loaded(status)
                    }
                case .files: FileBrowserView(repository: repository)
                case .actions: RepositoryActionsView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: repository.localURL) {
            statusState = .loading
            guard let url = repository.localURL else {
                statusState = .unavailable
                return
            }
            do { statusState = .loaded(try await model.git.status(at: url)) }
            catch {
                statusState = .unavailable
                model.showError(error.localizedDescription, title: "Couldn’t load repository status")
            }
        }
    }

    private func perform(_ requestedOperation: RepositoryOperation) {
        guard operation == nil, let url = repository.localURL else { return }
        operation = requestedOperation
        Task {
            defer { operation = nil }
            let toastID = model.showToast(
                title: "\(requestedOperation.progressTitle) \(repository.name)…",
                style: .information,
                showsActivity: true,
                isDismissible: false
            )
            do {
                switch requestedOperation {
                case .fetch: try await model.git.fetch(at: url)
                case .pull: try await model.git.pull(at: url)
                case .push: try await model.git.push(at: url)
                case .sync: try await model.git.sync(at: url)
                }
                statusState = .loaded(try await model.git.status(at: url))
                graphReloadToken += 1
                model.updateToast(
                    toastID,
                    title: requestedOperation.successTitle,
                    message: repository.name,
                    style: .success,
                    showsActivity: false,
                    isDismissible: true
                )
            } catch {
                model.updateToast(
                    toastID,
                    title: requestedOperation.failureTitle,
                    message: error.localizedDescription,
                    style: .error,
                    showsActivity: false,
                    isDismissible: true
                )
            }
        }
    }

    private func help(for operation: RepositoryOperation) -> String {
        switch operation {
        case .fetch: "Download remote references without changing the working tree"
        case .pull: "Fast-forward the current branch from its upstream"
        case .push: "Push the current branch to its upstream"
        case .sync: "Pull, then push the current branch"
        }
    }
}

private enum RepositoryOperation: String {
    case fetch = "Fetch"
    case pull = "Pull"
    case push = "Push"
    case sync = "Sync"

    var icon: String {
        switch self {
        case .fetch: "arrow.clockwise"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }

    var progressTitle: String {
        switch self {
        case .fetch: "Fetching"
        case .pull: "Pulling"
        case .push: "Pushing"
        case .sync: "Syncing"
        }
    }

    var successTitle: String { "\(rawValue) complete" }
    var failureTitle: String { "\(rawValue) failed" }
}

private enum LocalRepositoryStatusState {
    case loading
    case loaded(RepositoryStatus)
    case unavailable
}

private struct RepositoryHeader: View {
    let repository: Repository
    var localStatusState: LocalRepositoryStatusState?

    init(repository: Repository, localStatusState: LocalRepositoryStatusState? = nil) {
        self.repository = repository
        self.localStatusState = localStatusState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(repository.fullName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let description = repository.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            metadata
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repository-summary")
    }

    private var metadata: some View {
        HStack(spacing: 18) {
            Label(
                repository.isPrivate ? "Private" : "Public",
                systemImage: repository.isPrivate ? "lock.fill" : "globe"
            )
            branchStatus
            if let updatedAt = repository.updatedAt {
                Label {
                    Text("Updated \(CommitAgeFormatter.updatedString(for: updatedAt))")
                } icon: {
                    Image(systemName: "clock")
                }
            } else {
                Label("Update time unavailable", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let webURL = repository.webURL {
                Link(destination: webURL) {
                    Text(webURL.absoluteString)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(webURL.absoluteString)
            } else {
                Text("No GitHub URL")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var branchStatus: some View {
        if let localStatusState {
            switch localStatusState {
            case .loading:
                Label("Loading branch…", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            case let .loaded(status):
                HStack(spacing: 8) {
                    Label(status.branch, systemImage: "arrow.triangle.branch")
                    if status.ahead > 0 {
                        Label("\(status.ahead)", systemImage: "arrow.up").help("Commits ahead of origin")
                    }
                    if status.behind > 0 {
                        Label("\(status.behind)", systemImage: "arrow.down").help("Commits behind origin")
                    }
                    if status.hasChanges {
                        Circle()
                            .fill(status.hasMergeConflicts ? .red : .orange)
                            .frame(width: 8, height: 8)
                            .help(status.hasMergeConflicts ? "Merge conflicts" : "Uncommitted changes")
                    }
                }
            case .unavailable:
                Label(repository.defaultBranch ?? "Branch unavailable", systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label(repository.defaultBranch ?? "Branch unavailable", systemImage: "arrow.triangle.branch")
        }
    }
}

private struct RepositoryViewBar<Tab: Hashable & Identifiable & RawRepresentable, Actions: View>: View where Tab.RawValue == String {
    @Binding var selection: Tab
    let tabs: [Tab]
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 13)
                            .frame(minHeight: 28)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(ResponsiveButtonStyle(
                        isSelected: selection == tab,
                        shape: .capsule,
                        selectedBackground: .accentColor
                    ))
                    .foregroundStyle(selection == tab ? .white : .primary)
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                }
            }
            .padding(2)
            .background(.quaternary, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Repository view")

            Spacer(minLength: 20)
            HStack(spacing: 8) {
                actions
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct LocalReadmeView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    @State private var readme: String?
    @State private var loaded = false

    var body: some View {
        Group {
            if let readme {
                MarkdownPreviewView(
                    markdown: readme,
                    baseURL: repository.localURL
                )
            } else if loaded {
                ContentUnavailableView("No README", systemImage: "doc.text.magnifyingglass")
            } else {
                PaneLoadingView("Loading README…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            defer { loaded = true }
            guard let url = repository.localURL else { return }
            do { readme = try await model.git.readREADME(at: url) }
            catch { model.showError(error.localizedDescription, title: "Couldn’t load README") }
        }
    }
}

private struct RepositoryActionsView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository

    @State private var runs: [GitHubWorkflowRun] = []
    @State private var loading = true
    @State private var loadingMore = false
    @State private var hasMore = false
    @State private var loadError: String?
    @State private var columnWidths = ActionsColumnWidths.saved

    private let pageSize = 30

    var body: some View {
        Group {
            if model.githubToken.isEmpty {
                ContentUnavailableView(
                    "GitHub Token Required",
                    systemImage: "key",
                    description: Text("Add a GitHub token in Settings to view Actions runs.")
                )
            } else if repository.webURL?.host?.lowercased() != "github.com" {
                ContentUnavailableView(
                    "GitHub Repository Required",
                    systemImage: "bolt.slash",
                    description: Text("Actions are available for repositories connected to GitHub.")
                )
            } else if loading, runs.isEmpty {
                PaneLoadingView("Loading Actions…")
            } else if let loadError, runs.isEmpty {
                ContentUnavailableView {
                    Label("Couldn’t Load Actions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else if runs.isEmpty {
                ContentUnavailableView(
                    "No Actions Runs",
                    systemImage: "bolt",
                    description: Text("This repository has no GitHub Actions workflow runs.")
                )
            } else {
                actionsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: repository.id) { await reload() }
        .task(id: repository.id) { await monitorRunningRuns() }
    }

    private var actionsList: some View {
        GeometryReader { geometry in
            let displayedColumnWidths = columnWidths.fitting(totalWidth: geometry.size.width)
            VStack(alignment: .leading, spacing: 0) {
                ActionsHeaderRow(
                    columnWidths: $columnWidths,
                    displayedColumnWidths: displayedColumnWidths
                )
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(runs) { run in
                            ActionsRunRow(run: run, columnWidths: displayedColumnWidths)
                                .onAppear {
                                    guard run.id == runs.last?.id else { return }
                                    Task { await loadMoreRuns() }
                                }
                            Divider()
                        }
                        paginationRow
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .onChange(of: columnWidths) { _, newWidths in newWidths.save() }
    }

    @ViewBuilder
    private var paginationRow: some View {
        if loadingMore {
            ProgressView("Loading more runs…")
                .frame(maxWidth: .infinity)
                .padding()
        } else if hasMore {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding()
                .onAppear { Task { await loadMoreRuns() } }
        } else {
            Text("\(runs.count) runs loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func reload() async {
        guard !model.githubToken.isEmpty,
              repository.webURL?.host?.lowercased() == "github.com" else {
            loading = false
            return
        }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let page = try await fetchPage(offset: 0)
            guard !Task.isCancelled else { return }
            runs = page.runs
            hasMore = page.hasMore
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadMoreRuns() async {
        guard hasMore, !loading, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await fetchPage(offset: runs.count)
            guard !Task.isCancelled else { return }
            let existingIDs = Set(runs.map(\.id))
            runs.append(contentsOf: page.runs.filter { !existingIDs.contains($0.id) })
            hasMore = page.hasMore
        } catch is CancellationError {
            return
        } catch {
            model.showError(error.localizedDescription, title: "Couldn’t load more Actions runs")
        }
    }

    private func monitorRunningRuns() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard runs.contains(where: \.isRunning), !loading, !loadingMore else { continue }
            do {
                let page = try await fetchPage(offset: 0)
                guard !Task.isCancelled else { return }
                let refreshedIDs = Set(page.runs.map(\.id))
                runs = page.runs + runs.filter { !refreshedIDs.contains($0.id) }
            } catch {
                // Keep the existing list visible and try again on the next polling interval.
            }
        }
    }

    private func fetchPage(offset: Int) async throws -> GitHubWorkflowRunPage {
        try await model.github.workflowRunPage(
            fullName: repository.fullName,
            offset: offset,
            limit: pageSize,
            token: model.githubToken
        )
    }
}

struct ActionsColumnWidths: Equatable {
    enum Column {
        case status, commit, elapsed, started, workflow, author, branch
    }

    var status: CGFloat = 120
    var commit: CGFloat = 280
    var elapsed: CGFloat = 100
    var started: CGFloat = 170
    var workflow: CGFloat = 190
    var author: CGFloat = 150
    var branch: CGFloat = 140

    private static let defaultsKey = "actions.columnWidths.v1"

    var totalWidth: CGFloat { status + commit + elapsed + started + workflow + author + branch }

    func fitting(totalWidth: CGFloat) -> Self {
        guard self.totalWidth > 0, totalWidth > 0 else { return self }
        let scale = totalWidth / self.totalWidth
        var result = self
        result.status *= scale
        result.commit *= scale
        result.elapsed *= scale
        result.started *= scale
        result.workflow *= scale
        result.author *= scale
        result.branch *= scale
        return result
    }

    func resizing(_ column: Column, to proposedWidth: CGFloat) -> Self {
        var result = self
        let companion: Column = column == .commit ? .workflow : .commit
        let currentWidth = width(for: column)
        let companionWidth = width(for: companion)
        let desiredWidth = max(Self.minimumWidth(for: column), proposedWidth)
        let desiredDelta = desiredWidth - currentWidth
        let maximumGrowth = companionWidth - Self.minimumWidth(for: companion)
        let appliedDelta = min(desiredDelta, maximumGrowth)

        result.setWidth(currentWidth + appliedDelta, for: column)
        result.setWidth(companionWidth - appliedDelta, for: companion)
        return result
    }

    static var saved: Self {
        guard let values = UserDefaults.standard.array(forKey: defaultsKey) as? [Double],
              values.count == 7 else { return Self() }
        return Self(
            status: values[0],
            commit: values[1],
            elapsed: values[2],
            started: values[3],
            workflow: values[4],
            author: values[5],
            branch: values[6]
        )
    }

    func save() {
        UserDefaults.standard.set(
            [status, commit, elapsed, started, workflow, author, branch].map(Double.init),
            forKey: Self.defaultsKey
        )
    }

    func width(for column: Column) -> CGFloat {
        switch column {
        case .status: status
        case .commit: commit
        case .elapsed: elapsed
        case .started: started
        case .workflow: workflow
        case .author: author
        case .branch: branch
        }
    }

    private mutating func setWidth(_ width: CGFloat, for column: Column) {
        switch column {
        case .status: status = width
        case .commit: commit = width
        case .elapsed: elapsed = width
        case .started: started = width
        case .workflow: workflow = width
        case .author: author = width
        case .branch: branch = width
        }
    }

    private static func minimumWidth(for column: Column) -> CGFloat {
        switch column {
        case .status: 100
        case .commit: 160
        case .elapsed: 70
        case .started: 120
        case .workflow: 120
        case .author: 90
        case .branch: 90
        }
    }
}

private struct ActionsHeaderRow: View {
    @Binding var columnWidths: ActionsColumnWidths
    let displayedColumnWidths: ActionsColumnWidths

    var body: some View {
        HStack(spacing: 0) {
            header("Status", column: .status)
            header("Commit", column: .commit)
            header("Elapsed", column: .elapsed)
            header("Started", column: .started)
            header("Workflow", column: .workflow)
            header("Author", column: .author)
            header("Branch", column: .branch)
        }
        .frame(height: 28)
        .background(.bar)
    }

    private func header(_ title: String, column: ActionsColumnWidths.Column) -> some View {
        ResizableColumnHeader(
            title: title,
            width: Binding(
                get: { displayedColumnWidths.width(for: column) },
                set: { columnWidths = displayedColumnWidths.resizing(column, to: $0) }
            ),
            displayedWidth: displayedColumnWidths.width(for: column),
            minimumWidth: 1,
            leadingPadding: column == .status ? 18 : 8,
            trailingPadding: column == .status ? 10 : 8
        )
    }
}

private struct ActionsRunRow: View {
    let run: GitHubWorkflowRun
    let columnWidths: ActionsColumnWidths
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ActionsStatusLabel(status: run.displayStatus)
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .frame(width: columnWidths.status, alignment: .leading)
            Link(destination: run.webURL) {
                Text(run.commitTitle)
                    .bold()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .frame(width: columnWidths.commit, alignment: .leading)
            elapsedTime
                .padding(.horizontal, 10)
                .frame(width: columnWidths.elapsed, alignment: .leading)
            Text(Self.startDateFormatter.string(from: run.startedAt ?? run.createdAt))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(width: columnWidths.started, alignment: .leading)
            Text(run.workflowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: columnWidths.workflow, alignment: .leading)
            Text(run.commitAuthor)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 10)
                .frame(width: columnWidths.author, alignment: .leading)
            Label(run.branch, systemImage: "arrow.triangle.branch")
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(width: columnWidths.branch, alignment: .leading)
        }
        .font(.callout)
        .frame(height: 44)
        .background(isHovered ? Color.accentColor.opacity(0.09) : Color.clear)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .help(run.commitTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(run.workflowTitle), \(run.commitTitle), \(run.commitAuthor), \(run.branch)"
        )
    }

    @ViewBuilder
    private var elapsedTime: some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.elapsedFormatter.string(
                    from: run.elapsedTime(at: context.date)
                ) ?? "—")
                .monospacedDigit()
            }
        } else {
            Text(Self.elapsedFormatter.string(from: run.elapsedTime()) ?? "—")
                .monospacedDigit()
        }
    }

    private static let startDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}

private struct ActionsStatusLabel: View {
    let status: GitHubWorkflowRunDisplayStatus

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var title: String {
        switch status {
        case .inProgress: "In Progress"
        case .complete: "Complete"
        case .failed: "Failed"
        }
    }

    private var icon: String {
        switch status {
        case .inProgress: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .inProgress: .blue
        case .complete: .green
        case .failed: .red
        }
    }
}
