import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var repositories: [Repository] = []
    @Published var organizations: [String] = []
    @Published var selectedOrganization = "All"
    @Published var repositoryFilter: RepositoryFilter = .all
    @Published var selectedRepositoryID: Repository.ID?
    @Published var searchText = ""
    @Published var githubToken = TokenStore.initialToken()
    @Published var reposDirectory: URL?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var gitAvailability: GitAvailability = .checking

    let git = GitService()
    let github = GitHubService()
    private var remoteRepositories: [Repository] = []
    private var localRepositories: [Repository] = []

    var selectedRepository: Repository? {
        repositories.first { $0.id == selectedRepositoryID }
    }

    var visibleRepositories: [Repository] {
        repositories.filter { repository in
            let matchesOrganization = selectedOrganization == "All" || repository.owner == selectedOrganization
            let matchesFilter = switch repositoryFilter {
            case .all: true
            case .local: repository.isLocal
            case .remoteOnly: !repository.isLocal
            }
            let matchesSearch = searchText.isEmpty ||
                repository.fullName.localizedCaseInsensitiveContains(searchText) ||
                (repository.description?.localizedCaseInsensitiveContains(searchText) ?? false)
            return matchesOrganization && matchesFilter && matchesSearch
        }
    }

    func start() async {
        gitAvailability = await git.availability()
        var stale = false
        if let bookmark = UserDefaults.standard.data(forKey: "reposDirectoryBookmark"),
           let url = try? URL(
               resolvingBookmarkData: bookmark,
               options: [.withSecurityScope],
               relativeTo: nil,
               bookmarkDataIsStale: &stale
           ) {
            reposDirectory = url
            _ = url.startAccessingSecurityScopedResource()
        }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if let reposDirectory, gitAvailability.isAvailable {
                localRepositories = try await git.discoverRepositories(in: reposDirectory)
            }
            if !githubToken.isEmpty {
                async let repos = github.repositories(token: githubToken)
                async let orgs = github.organizations(token: githubToken)
                remoteRepositories = try await repos
                organizations = Array(Set(try await orgs + remoteRepositories.map(\.owner))).sorted()
            }
            mergeRepositories()
            errorMessage = nil
        } catch {
            mergeRepositories()
            errorMessage = error.localizedDescription
        }
    }

    func saveToken() async {
        TokenStore.save(githubToken.trimmingCharacters(in: .whitespacesAndNewlines))
        githubToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        await refresh()
    }

    func chooseReposDirectory() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repositories Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        reposDirectory = url
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "reposDirectoryBookmark")
        }
        await refresh()
    }

    func clone(_ repository: Repository) async {
        guard let cloneURL = repository.cloneURL, let root = reposDirectory else {
            errorMessage = "Choose a local repositories folder in Settings before cloning."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await git.clone(
                remote: cloneURL,
                into: root.appendingPathComponent(repository.name),
                token: githubToken
            )
            await refresh()
            selectedRepositoryID = repository.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeRepositories() {
        var merged: [String: Repository] = [:]
        for remote in remoteRepositories { merged[remote.fullName.lowercased()] = remote }
        for local in localRepositories {
            let key = local.fullName.lowercased()
            if var existing = merged[key] {
                existing.localURL = local.localURL
                merged[key] = existing
            } else {
                merged[key] = local
            }
        }
        repositories = merged.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        if selectedRepositoryID == nil { selectedRepositoryID = repositories.first?.id }
    }
}
