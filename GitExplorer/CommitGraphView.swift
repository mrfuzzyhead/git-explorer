import SwiftUI

struct CommitGraphView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    var reloadToken = 0
    var onStatusChange: (RepositoryStatus) -> Void = { _ in }

    @State private var commits: [GitCommit] = []
    @State private var allLayouts: [CommitLayout] = []
    @State private var workingTreeLayout: CommitLayout?
    @State private var selectedCommit: GitCommit?
    @State private var hoveredCommitID: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var hasMoreCommits = false
    @State private var repositoryStatus: RepositoryStatus?
    @State private var repositoryStateFingerprint: String?
    @State private var loadedRepositoryID: Repository.ID?
    @State private var selectedBranch: String?
    @State private var selectedCommitID: String?
    @State private var recentBranches: [String] = []
    @State private var renamePresented = false
    @State private var createBranchPresented = false
    @State private var renamedBranch = ""
    @State private var newBranchName = ""
    @State private var columnWidths = CommitGraphColumnWidths.saved
    @AppStorage("commitDetails.panelWidth") private var commitDetailsPanelWidth = 360.0
    @GestureState private var commitDetailsPanelDragOffset: CGFloat = 0

    private let minimumGraphWidth: CGFloat = 460
    private let minimumCommitDetailsWidth: CGFloat = 280
    private let commitDetailsResizeHandleWidth: CGFloat = 8

    private var layouts: [CommitLayout] {
        allLayouts
    }

    private var highlightedIDs: Set<String> {
        guard let hoveredCommitID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        var result: Set<String> = [hoveredCommitID]
        var pending = [hoveredCommitID]
        while let id = pending.popLast(), let commit = byID[id] {
            for parent in commit.parents where result.insert(parent).inserted { pending.append(parent) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            if loading, layouts.isEmpty, workingTreeLayout == nil {
                ProgressView("Loading commit history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layouts.isEmpty, workingTreeLayout == nil {
                ContentUnavailableView(
                    "No Commits",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("This repository has no commit history to display.")
                )
            } else {
                graphContent
            }
        }
        .task(id: "\(repository.id)-\(reloadToken)") {
            await reload()
            if reloadToken == 0 {
                await fetchRemotesAndReloadIfNeeded()
            }
        }
        .task(id: repository.id) { await monitorLocalRepository() }
        .onChange(of: columnWidths) { _, newWidths in
            newWidths.save()
        }
        .alert("Rename Branch", isPresented: $renamePresented) {
            TextField("New branch name", text: $renamedBranch)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { performBranchAction(.rename(renamedBranch)) }
        }
        .alert("Create Branch", isPresented: $createBranchPresented) {
            TextField("Branch name", text: $newBranchName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { performBranchAction(.create(newBranchName, selectedCommitID ?? "HEAD")) }
        } message: {
            Text("Create a branch at the selected point in the graph.")
        }
    }

    private var graphList: some View {
        CommitGraphList(
            layouts: layouts,
            highlightedIDs: highlightedIDs,
            hoveredCommitID: $hoveredCommitID,
            selectedCommit: $selectedCommit,
            repositoryStatus: repositoryStatus,
            workingTreeLayout: workingTreeLayout,
            hasMergeConflicts: repositoryStatus?.hasMergeConflicts == true,
            recentBranches: recentBranches,
            canManageBranches: repository.localURL != nil,
            onBranchAction: handleBranchMenuAction,
            loadedCommitCount: commits.count,
            hasMoreCommits: hasMoreCommits,
            loadingMore: loadingMore,
            columnWidths: $columnWidths,
            loadMore: { Task { await loadMore() } }
        )
    }

    @ViewBuilder
    private var graphContent: some View {
        if let selectedCommit {
            GeometryReader { geometry in
                let previewWidth = clampedCommitDetailsPanelWidth(
                    CGFloat(commitDetailsPanelWidth) - commitDetailsPanelDragOffset,
                    containerWidth: geometry.size.width
                )

                HStack(spacing: 0) {
                    graphList
                        .frame(
                            width: max(
                                0,
                                geometry.size.width - previewWidth - commitDetailsResizeHandleWidth
                            )
                        )

                    commitDetailsResizeHandle(containerWidth: geometry.size.width)

                    CommitDetailsPanel(
                        repository: repository,
                        commit: selectedCommit,
                        isWorkingTree: selectedCommit.id == workingTreeLayout?.id,
                        hasMergeConflicts: repositoryStatus?.hasMergeConflicts == true,
                        onClose: { self.selectedCommit = nil },
                        onCommit: {
                            self.selectedCommit = nil
                            Task { await reload(showsRefreshToast: false) }
                        }
                    )
                    .environmentObject(model)
                    .frame(width: previewWidth)
                }
            }
        } else {
            graphList
        }
    }

    private func clampedCommitDetailsPanelWidth(
        _ proposedWidth: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, containerWidth - commitDetailsResizeHandleWidth)
        let effectiveMinimumPreviewWidth = min(minimumCommitDetailsWidth, availableWidth)
        let effectiveMinimumGraphWidth = min(
            minimumGraphWidth,
            max(0, availableWidth - effectiveMinimumPreviewWidth)
        )
        let maximumPreviewWidth = max(
            effectiveMinimumPreviewWidth,
            availableWidth - effectiveMinimumGraphWidth
        )
        return min(max(proposedWidth, effectiveMinimumPreviewWidth), maximumPreviewWidth)
    }

    private func commitDetailsResizeHandle(containerWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: commitDetailsResizeHandleWidth)
            .overlay {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($commitDetailsPanelDragOffset) { value, offset, transaction in
                        transaction.animation = nil
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        let resolvedWidth = clampedCommitDetailsPanelWidth(
                            CGFloat(commitDetailsPanelWidth) - value.translation.width,
                            containerWidth: containerWidth
                        )
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            commitDetailsPanelWidth = Double(resolvedWidth)
                        }
                    }
            )
            .help("Drag to resize the commit preview")
    }

    private var pageSize: Int { repository.isLocal ? 500 : 100 }
    private var localRepositoryCheckInterval: Duration { .seconds(5) }

    private func reload(
        showsRefreshToast: Bool = true,
        reportsErrors: Bool = true
    ) async {
        let hasCurrentHistory = loadedRepositoryID == repository.id &&
            (!commits.isEmpty || workingTreeLayout != nil)
        let toastID = hasCurrentHistory && showsRefreshToast
            ? model.showToast(
                title: "Refreshing commit history…",
                message: repository.name,
                style: .information,
                showsActivity: true,
                isDismissible: false
            )
            : nil

        loading = true
        loadingMore = false
        if !hasCurrentHistory {
            commits = []
            allLayouts = []
            workingTreeLayout = nil
            selectedCommit = nil
            hasMoreCommits = false
            repositoryStatus = nil
        }
        defer { loading = false }
        if let url = repository.localURL {
            repositoryStatus = try? await model.git.status(at: url)
            recentBranches = (try? await model.git.recentBranches(at: url)) ?? []
            if let repositoryStatus { onStatusChange(repositoryStatus) }
        }
        do {
            try await loadPage(offset: 0)
            loadedRepositoryID = repository.id
            if let url = repository.localURL {
                repositoryStateFingerprint = try? await model.git.repositoryStateFingerprint(at: url)
            }
            if let toastID {
                model.updateToast(
                    toastID,
                    title: "Commit history refreshed",
                    message: repository.name,
                    style: .success,
                    showsActivity: false,
                    isDismissible: true
                )
            }
        } catch {
            if let toastID {
                model.updateToast(
                    toastID,
                    title: "Couldn’t refresh commit history",
                    message: error.localizedDescription,
                    style: .error,
                    showsActivity: false,
                    isDismissible: true
                )
            } else if reportsErrors {
                model.showError(error.localizedDescription, title: "Couldn’t load commit history")
            }
        }
    }

    private func monitorLocalRepository() async {
        guard let url = repository.localURL else { return }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: localRepositoryCheckInterval)
            } catch {
                return
            }
            guard !Task.isCancelled, !loading, !loadingMore else { continue }
            guard let fingerprint = try? await model.git.repositoryStateFingerprint(at: url) else {
                continue
            }
            guard let previousFingerprint = repositoryStateFingerprint else {
                repositoryStateFingerprint = fingerprint
                continue
            }
            guard fingerprint != previousFingerprint else { continue }
            guard !loading, !loadingMore else { continue }

            await reload(
                showsRefreshToast: false,
                reportsErrors: false
            )
        }
    }

    private func fetchRemotesAndReloadIfNeeded() async {
        guard let url = repository.localURL else { return }

        do {
            try await model.git.fetch(at: url)
        } catch {
            guard !Task.isCancelled else { return }
            model.showError(error.localizedDescription, title: "Couldn’t refresh remotes")
            return
        }
        guard !Task.isCancelled else { return }

        let fingerprint = try? await model.git.repositoryStateFingerprint(at: url)
        guard !Task.isCancelled, fingerprint != repositoryStateFingerprint else { return }
        await reload(
            showsRefreshToast: false,
            reportsErrors: false
        )
    }

    private func loadMore() async {
        guard hasMoreCommits, !loading, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            try await loadPage(offset: commits.count)
        } catch {
            model.showError(error.localizedDescription, title: "Couldn’t load commit history")
        }
    }

    private func loadPage(offset: Int) async throws {
        let page: GitCommitPage
        if let url = repository.localURL {
            page = try await model.git.commitPage(at: url, offset: offset, limit: pageSize)
        } else {
            guard !model.githubToken.isEmpty else { return }
            page = try await model.github.commitPage(
                fullName: repository.fullName,
                branch: repository.defaultBranch,
                offset: offset,
                limit: pageSize,
                token: model.githubToken
            )
        }
        let combined = offset == 0 ? page.commits : commits + page.commits
        let linkedCommits = Self.linkingChildren(in: combined)
        let hasUncommittedChanges = repositoryStatus?.hasChanges == true
        let hasMergeConflicts = repositoryStatus?.hasMergeConflicts == true
        let graphLayout = await Task.detached(priority: .userInitiated) {
            GitGraphLayout.makeRepositoryLayout(
                commits: linkedCommits,
                hasUncommittedChanges: hasUncommittedChanges,
                hasMergeConflicts: hasMergeConflicts
            )
        }.value
        guard !Task.isCancelled else { return }
        commits = linkedCommits
        allLayouts = graphLayout.commits
        workingTreeLayout = graphLayout.workingTree
        hasMoreCommits = page.hasMore
    }

    private static func linkingChildren(in commits: [GitCommit]) -> [GitCommit] {
        var children: [String: [String]] = [:]
        for commit in commits {
            for parent in commit.parents {
                children[parent, default: []].append(commit.id)
            }
        }
        var result = commits
        for index in result.indices {
            result[index].children = children[result[index].id] ?? []
        }
        return result
    }

    private func handleBranchMenuAction(_ action: BranchMenuAction) {
        switch action {
        case let .checkout(branch):
            selectedBranch = branch
            performBranchAction(.checkout)
        case let .rename(branch):
            selectedBranch = branch
            renamedBranch = branch
            renamePresented = true
        case let .createBranch(source, commitID):
            selectedBranch = source
            selectedCommitID = commitID
            newBranchName = ""
            createBranchPresented = true
        case let .merge(source, target):
            selectedBranch = source
            performBranchAction(.merge(target: target))
        }
    }

    private func performBranchAction(_ action: BranchAction) {
        guard let branch = selectedBranch, let url = repository.localURL else { return }
        Task {
            let toastID = model.showToast(
                title: action.progressTitle(for: branch),
                style: .information,
                showsActivity: true,
                isDismissible: false
            )
            do {
                switch action {
                case .checkout: try await model.git.checkout(branch: branch, at: url)
                case let .rename(newName):
                    try await model.git.rename(branch: branch, to: newName, at: url)
                case let .create(newName, commitID):
                    try await model.git.createBranch(newName, at: commitID, in: url)
                case let .merge(target):
                    try await model.git.merge(branch: branch, into: target, at: url)
                }
                if action.requiresReload {
                    await reload(showsRefreshToast: false)
                }
                model.updateToast(
                    toastID,
                    title: action.successTitle,
                    message: branch,
                    style: .success,
                    showsActivity: false,
                    isDismissible: true
                )
            } catch {
                if case .merge = action,
                   let status = try? await model.git.status(at: url),
                   status.hasMergeConflicts {
                    await reload(showsRefreshToast: false, reportsErrors: false)
                    model.updateToast(
                        toastID,
                        title: "There were merge conflicts",
                        message: "\(status.conflictedFileCount) \(status.conflictedFileCount == 1 ? "file needs" : "files need") resolution.",
                        style: .warning,
                        showsActivity: false,
                        isDismissible: true
                    )
                    return
                }
                model.updateToast(
                    toastID,
                    title: action.failureTitle,
                    message: error.localizedDescription,
                    style: .error,
                    showsActivity: false,
                    isDismissible: true
                )
            }
        }
    }
}

private enum BranchAction {
    case checkout, rename(String), create(String, String), merge(target: String)
    var requiresReload: Bool { true }

    func progressTitle(for branch: String) -> String {
        switch self {
        case .checkout: "Checking out \(branch)…"
        case .rename: "Renaming \(branch)…"
        case .create: "Creating branch…"
        case let .merge(target): "Merging \(branch) into \(target)…"
        }
    }

    var successTitle: String {
        switch self {
        case .checkout: "Checkout complete"
        case .rename: "Branch renamed"
        case .create: "Branch created"
        case .merge: "Merge complete"
        }
    }

    var failureTitle: String {
        switch self {
        case .checkout: "Checkout failed"
        case .rename: "Rename failed"
        case .create: "Create branch failed"
        case .merge: "Merge failed"
        }
    }
}
