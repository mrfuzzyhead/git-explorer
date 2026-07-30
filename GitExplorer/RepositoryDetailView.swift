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

    var body: some View {
        VStack(spacing: 0) {
            RepositoryHeader(repository: repository) {
                Button {
                    Task { await model.clone(repository) }
                } label: {
                    Label("Clone", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                if let url = repository.webURL {
                    Link(destination: url) {
                        Label("Open on GitHub", systemImage: "safari")
                    }
                }
            }
            remoteMetadata
            Divider()
            if loading {
                ProgressView("Loading README…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let readme {
                MarkdownPreviewView(markdown: readme, baseURL: repository.webURL)
            } else {
                ContentUnavailableView(
                    "No README",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("This repository does not contain a README.")
                )
            }
        }
        .task {
            defer { loading = false }
            guard !model.githubToken.isEmpty else { return }
            do {
                readme = try await model.github.readme(fullName: repository.fullName, token: model.githubToken)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private var remoteMetadata: some View {
        HStack(spacing: 18) {
            Label(repository.isPrivate ? "Private" : "Public", systemImage: repository.isPrivate ? "lock.fill" : "globe")
            if let branch = repository.defaultBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
            }
            if let updatedAt = repository.updatedAt {
                Label {
                    Text("Updated \(updatedAt, style: .relative)")
                } icon: {
                    Image(systemName: "clock")
                }
            }
            Spacer()
            if let cloneURL = repository.cloneURL {
                Text(cloneURL.absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

private struct LocalRepositoryView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    @State private var selection = LocalTab.readme
    @State private var statusState = LocalRepositoryStatusState.loading

    enum LocalTab: String, CaseIterable, Identifiable {
        case readme = "README"
        case graph = "Git Graph"
        case files = "Files"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            LocalRepositorySummary(repository: repository, statusState: statusState)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Divider()
            Picker("View", selection: $selection) {
                ForEach(LocalTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .padding(10)
            Divider()
            Group {
                switch selection {
                case .readme: LocalReadmeView(repository: repository)
                case .graph: CommitGraphView(repository: repository)
                case .files: FileBrowserView(repository: repository)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: repository.localURL) {
            statusState = .loading
            guard let url = repository.localURL else {
                statusState = .unavailable
                return
            }
            do { statusState = .loaded(try await model.git.status(at: url)) }
            catch {
                statusState = .unavailable
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private enum LocalRepositoryStatusState {
    case loading
    case loaded(RepositoryStatus)
    case unavailable
}

private struct LocalRepositorySummary: View {
    let repository: Repository
    let statusState: LocalRepositoryStatusState

    var body: some View {
        RepositoryHeader(repository: repository) {
            statusView
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("local-repository-summary")
    }

    @ViewBuilder
    private var statusView: some View {
        switch statusState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .help("Loading repository status")
                .accessibilityLabel("Loading repository status")
        case let .loaded(status):
            loadedStatus(status)
        case .unavailable:
            Label("Status unavailable", systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func loadedStatus(_ status: RepositoryStatus) -> some View {
        HStack(spacing: 8) {
            Label(status.branch, systemImage: "arrow.triangle.branch")
                .fontWeight(.medium)
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
        .font(.callout)
    }
}

struct RepositoryHeader<Actions: View>: View {
    let repository: Repository
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(repository.fullName)
                    .font(.title2.bold())
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let description = repository.description {
                    Text(description).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            actions
        }
        .padding(16)
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
                ProgressView()
            }
        }
        .task {
            defer { loaded = true }
            guard let url = repository.localURL else { return }
            do { readme = try await model.git.readREADME(at: url) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
