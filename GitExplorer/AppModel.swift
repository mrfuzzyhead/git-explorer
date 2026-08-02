import AppKit
import Foundation

enum GitHubConnectionStatus: Equatable {
    case notConfigured
    case checking
    case connected(username: String)
    case failed(message: String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var repositories: [Repository] = []
    @Published var organizations: [String] = []
    @Published var selectedOrganization = "All"
    @Published var repositoryFilter: RepositoryFilter = .all
    @Published var selectedRepositoryID: Repository.ID? {
        didSet {
            defaults.set(selectedRepositoryID, forKey: Self.selectedRepositoryDefaultsKey)
        }
    }
    @Published var searchText = ""
    @Published var githubToken = TokenStore.initialToken()
    @Published var reposDirectory: URL?
    @Published var isLoading = false
    @Published var gitAvailability: GitAvailability = .checking
    @Published var githubConnectionStatus: GitHubConnectionStatus = .notConfigured
    @Published private(set) var githubAccountName: String?
    @Published private(set) var toasts: [AppToast] = []
    @Published private(set) var cloningRepositoryIDs: Set<Repository.ID> = []

    let git = GitService()
    let github = GitHubService()
    private let defaults: UserDefaults
    private var remoteRepositories: [Repository] = []
    private var localRepositories: [Repository] = []
    private var toastDismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var initialRefreshTask: Task<Void, Never>?

    private static let repositoryCacheDefaultsKey = "repositoryCache.v1"
    private static let selectedRepositoryDefaultsKey = "selectedRepositoryID"
    private static let initialRefreshDelay = Duration.milliseconds(750)

    private struct RepositoryCache: Codable {
        let localRepositories: [Repository]
        let remoteRepositories: [Repository]
        let organizations: [String]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreRepositoryCache()
    }

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
        await testGitHubConnection()
        scheduleInitialRefresh()
    }

    func refresh() async {
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
        await refreshRepositories()
    }

    private func scheduleInitialRefresh() {
        initialRefreshTask?.cancel()
        initialRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.initialRefreshDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            initialRefreshTask = nil
            await refreshRepositories()
        }
    }

    private func refreshRepositories() async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }
        let toastID = showToast(
            title: repositories.isEmpty ? "Loading repositories…" : "Refreshing repositories…",
            message: "Checking local and GitHub repositories.",
            style: .information,
            showsActivity: true,
            isDismissible: false
        )
        do {
            if let reposDirectory, gitAvailability.isAvailable {
                localRepositories = try await git.discoverRepositories(in: reposDirectory)
            }
            if !githubToken.isEmpty, case .connected = githubConnectionStatus {
                async let repos = github.repositories(token: githubToken)
                async let orgs = github.organizations(token: githubToken)
                remoteRepositories = try await repos
                organizations = Array(Set(try await orgs + remoteRepositories.map(\.owner))).sorted()
            } else if githubToken.isEmpty {
                remoteRepositories = []
                organizations = []
            }
            mergeRepositories()
            saveRepositoryCache()
            updateToast(
                toastID,
                title: "Repositories updated",
                message: String(repositories.count) + " repositories are available.",
                style: .success,
                showsActivity: false,
                isDismissible: true
            )
        } catch {
            mergeRepositories()
            saveRepositoryCache()
            updateToast(
                toastID,
                title: "Repository refresh failed",
                message: error.localizedDescription,
                style: .error,
                showsActivity: false,
                isDismissible: true
            )
        }
    }

    func saveToken() async {
        TokenStore.save(githubToken.trimmingCharacters(in: .whitespacesAndNewlines))
        githubToken = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        await testGitHubConnection()
        if case .connected = githubConnectionStatus {
            await refresh()
        } else {
            remoteRepositories = []
            organizations = []
            mergeRepositories()
            saveRepositoryCache()
        }
    }

    func githubCredentialsChanged() {
        githubAccountName = nil
        githubConnectionStatus = .notConfigured
    }

    func testGitHubConnection() async {
        let token = githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            githubConnectionStatus = .notConfigured
            return
        }

        githubConnectionStatus = .checking
        do {
            let account = try await github.account(token: token)
            guard token == githubToken.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            githubAccountName = account.login
            githubConnectionStatus = .connected(username: account.login)
        } catch is CancellationError {
            return
        } catch {
            guard token == githubToken.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            githubConnectionStatus = .failed(message: error.localizedDescription)
        }
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
        guard let cloneURL = repository.cloneURL else {
            showError("A clone URL is not available for this repository.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = reposDirectory
        panel.prompt = "Clone Here"
        panel.message = "Choose a destination folder. \(repository.name) will be cloned into a new subfolder."
        guard panel.runModal() == .OK, let root = panel.url else { return }

        let destination = root.appendingPathComponent(repository.name, isDirectory: true)
        let toastID = showToast(
            title: "Cloning \(repository.name)…",
            message: destination.path(percentEncoded: false),
            style: .information,
            showsActivity: true,
            isDismissible: false
        )
        cloningRepositoryIDs.insert(repository.id)
        defer { cloningRepositoryIDs.remove(repository.id) }
        do {
            try await git.clone(
                remote: cloneURL,
                into: destination,
                token: githubToken
            )
            await refresh()
            selectedRepositoryID = repository.id
            updateToast(
                toastID,
                title: "Clone complete",
                message: "\(repository.name) was cloned to \(destination.path(percentEncoded: false)).",
                style: .success,
                showsActivity: false,
                isDismissible: true
            )
        } catch {
            updateToast(
                toastID,
                title: "Clone failed",
                message: error.localizedDescription,
                style: .error,
                showsActivity: false,
                isDismissible: true
            )
        }
    }

    @discardableResult
    func showToast(
        title: String,
        message: String? = nil,
        style: AppToastStyle = .information,
        showsActivity: Bool = false,
        isDismissible: Bool = true,
        autoDismissAfter: TimeInterval? = 5
    ) -> UUID {
        let toast = AppToast(
            id: UUID(),
            title: title,
            message: message,
            style: style,
            showsActivity: showsActivity,
            isDismissible: isDismissible
        )
        toasts.append(toast)
        scheduleToastDismissal(toast.id, after: autoDismissAfter)
        return toast.id
    }

    func updateToast(
        _ id: UUID,
        title: String,
        message: String? = nil,
        style: AppToastStyle,
        showsActivity: Bool,
        isDismissible: Bool,
        autoDismissAfter: TimeInterval? = 5
    ) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        toasts[index].title = title
        toasts[index].message = message
        toasts[index].style = style
        toasts[index].showsActivity = showsActivity
        toasts[index].isDismissible = isDismissible
        scheduleToastDismissal(id, after: autoDismissAfter)
    }

    func dismissToast(_ id: UUID) {
        guard toasts.first(where: { $0.id == id })?.isDismissible == true else { return }
        toastDismissalTasks[id]?.cancel()
        toastDismissalTasks[id] = nil
        toasts.removeAll { $0.id == id }
    }

    func showError(_ message: String, title: String = "Something went wrong") {
        showToast(title: title, message: message, style: .error)
    }

    private func scheduleToastDismissal(_ id: UUID, after duration: TimeInterval?) {
        toastDismissalTasks[id]?.cancel()
        toastDismissalTasks[id] = nil

        guard toasts.first(where: { $0.id == id })?.isDismissible == true,
              let duration,
              duration > 0 else {
            return
        }

        toastDismissalTasks[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            self?.expireToast(id)
        }
    }

    private func expireToast(_ id: UUID) {
        guard toasts.first(where: { $0.id == id })?.isDismissible == true else { return }
        toastDismissalTasks[id] = nil
        toasts.removeAll { $0.id == id }
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
        if selectedRepositoryID == nil || !repositories.contains(where: { $0.id == selectedRepositoryID }) {
            selectedRepositoryID = repositories.first?.id
        }
    }

    private func restoreRepositoryCache() {
        guard let data = defaults.data(forKey: Self.repositoryCacheDefaultsKey),
              let cache = try? JSONDecoder().decode(RepositoryCache.self, from: data) else {
            return
        }

        let cachedSelection = defaults.string(forKey: Self.selectedRepositoryDefaultsKey)
        localRepositories = cache.localRepositories
        remoteRepositories = cache.remoteRepositories
        organizations = cache.organizations
        mergeRepositories()

        if let selectedID = cachedSelection,
           repositories.contains(where: { $0.id == selectedID }) {
            selectedRepositoryID = selectedID
        }
    }

    private func saveRepositoryCache() {
        let cache = RepositoryCache(
            localRepositories: localRepositories,
            remoteRepositories: remoteRepositories,
            organizations: organizations
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: Self.repositoryCacheDefaultsKey)
    }
}
