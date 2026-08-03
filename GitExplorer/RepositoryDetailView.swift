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
                        Circle().fill(.orange).frame(width: 8, height: 8).help("Uncommitted changes")
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
                    .buttonStyle(.plain)
                    .background {
                        if selection == tab {
                            Capsule().fill(Color.accentColor)
                        }
                    }
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
