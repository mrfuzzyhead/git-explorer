import AppKit
import Foundation

enum AccountConnectionStatus: Equatable {
    case notConfigured
    case checking
    case connected(username: String)
    case failed(message: String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
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
    @Published private(set) var accounts: [SourceControlAccount] = []
    @Published private(set) var accountConnectionStatuses: [UUID: AccountConnectionStatus] = [:]
    @Published var openAIAPIKey = OpenAIKeyStore.read()
    @Published var reposDirectory: URL?
    @Published var isLoading = false
    @Published var gitAvailability: GitAvailability = .checking
    @Published private(set) var toasts: [AppToast] = []
    @Published private(set) var cloningRepositoryIDs: Set<Repository.ID> = []

    let git = GitService()
    let github = GitHubService()
    let azureDevOps = AzureDevOpsService()
    private let defaults: UserDefaults
    private var remoteRepositories: [Repository] = []
    private var localRepositories: [Repository] = []
    private var toastDismissalTasks: [UUID: Task<Void, Never>] = [:]
    private var initialRefreshTask: Task<Void, Never>?

    private static let repositoryCacheDefaultsKey = "repositoryCache.v1"
    private static let selectedRepositoryDefaultsKey = "selectedRepositoryID"
    private static let accountMigrationDefaultsKey = "sourceControlAccounts.didMigrateLegacyGitHub.v1"
    private static let initialRefreshDelay = Duration.milliseconds(750)

    private struct RepositoryCache: Codable {
        let localRepositories: [Repository]
        let remoteRepositories: [Repository]
        let organizations: [String]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accounts = SourceControlAccountStore.load(defaults: defaults)
        migrateLegacyGitHubAccountIfNeeded()
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
        for account in accounts {
            await testConnection(for: account.id)
        }
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
            message: "Checking local and connected account repositories.",
            style: .information,
            showsActivity: true,
            isDismissible: false
        )
        do {
            if let reposDirectory, gitAvailability.isAvailable {
                localRepositories = try await git.discoverRepositories(in: reposDirectory)
            }
            var loadedRemoteRepositories: [Repository] = []
            var loadedOrganizations: [String] = []
            for account in accounts where accountConnectionStatuses[account.id]?.isConnected == true {
                let token = SourceControlAccountStore.token(for: account.id)
                switch account.provider {
                case .github:
                    async let repos = github.repositories(token: token)
                    async let orgs = github.organizations(token: token)
                    let accountRepositories = try await repos.map {
                        var repository = $0
                        repository.sourceProvider = .github
                        repository.sourceAccountID = account.id
                        return repository
                    }
                    loadedRemoteRepositories.append(contentsOf: accountRepositories)
                    loadedOrganizations.append(contentsOf: try await orgs)
                case .azureDevOps:
                    guard let organization = account.organization else { continue }
                    loadedRemoteRepositories.append(contentsOf: try await azureDevOps.repositories(
                        organization: organization,
                        accountID: account.id,
                        token: token
                    ))
                }
            }
            remoteRepositories = loadedRemoteRepositories
            organizations = Array(Set(loadedOrganizations + remoteRepositories.map(\.owner))).sorted()
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

    func addAccount(provider: SourceControlProvider, organization: String?, token: String) async throws {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID()
        let displayName: String
        switch provider {
        case .github:
            displayName = try await github.account(token: token).login
        case .azureDevOps:
            guard let organization, !organization.isEmpty else { throw AzureDevOpsError.invalidOrganization }
            displayName = try await azureDevOps.account(organization: organization, token: token).displayName
        }
        let account = SourceControlAccount(
            id: id,
            provider: provider,
            displayName: displayName,
            organization: provider == .azureDevOps ? organization : nil
        )
        accounts.append(account)
        SourceControlAccountStore.saveToken(token, for: id)
        SourceControlAccountStore.save(accounts, defaults: defaults)
        accountConnectionStatuses[id] = .connected(username: displayName)
        await refresh()
    }

    func removeAccount(_ account: SourceControlAccount) async {
        accounts.removeAll { $0.id == account.id }
        accountConnectionStatuses[account.id] = nil
        SourceControlAccountStore.remove(account.id)
        SourceControlAccountStore.save(accounts, defaults: defaults)
        remoteRepositories.removeAll { $0.sourceAccountID == account.id }
        organizations = Array(Set(remoteRepositories.map(\.owner))).sorted()
        mergeRepositories()
        saveRepositoryCache()
    }

    func saveOpenAIAPIKey() {
        let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        openAIAPIKey = trimmed
        OpenAIKeyStore.save(trimmed)
    }

    func testConnection(for accountID: UUID) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let token = SourceControlAccountStore.token(for: accountID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            accountConnectionStatuses[accountID] = .notConfigured
            return
        }

        accountConnectionStatuses[accountID] = .checking
        do {
            let name: String
            switch account.provider {
            case .github:
                name = try await github.account(token: token).login
            case .azureDevOps:
                guard let organization = account.organization else { throw AzureDevOpsError.invalidOrganization }
                name = try await azureDevOps.account(organization: organization, token: token).displayName
            }
            guard SourceControlAccountStore.token(for: accountID) == token else { return }
            if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                accounts[index].displayName = name
                SourceControlAccountStore.save(accounts, defaults: defaults)
            }
            accountConnectionStatuses[accountID] = .connected(username: name)
        } catch is CancellationError {
            return
        } catch {
            guard SourceControlAccountStore.token(for: accountID) == token else { return }
            accountConnectionStatuses[accountID] = .failed(message: error.localizedDescription)
        }
    }

    func token(for repository: Repository) -> String {
        guard let accountID = repository.sourceAccountID else {
            return accounts.first(where: { $0.provider == .github }).map {
                SourceControlAccountStore.token(for: $0.id)
            } ?? ""
        }
        return SourceControlAccountStore.token(for: accountID)
    }

    func account(for repository: Repository) -> SourceControlAccount? {
        repository.sourceAccountID.flatMap { id in accounts.first { $0.id == id } }
    }

    func remoteReadme(for repository: Repository) async throws -> String? {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else { throw AzureDevOpsError.invalidOrganization }
            return try await azureDevOps.readme(repository: repository, organization: organization, token: token)
        case .github, .none:
            return try await github.readme(fullName: repository.fullName, token: token)
        }
    }

    func remoteCommitPage(for repository: Repository, offset: Int, limit: Int) async throws -> GitCommitPage {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else { throw AzureDevOpsError.invalidOrganization }
            return try await azureDevOps.commitPage(repository: repository, offset: offset, limit: limit, organization: organization, token: token)
        case .github, .none:
            return try await github.commitPage(fullName: repository.fullName, branch: repository.defaultBranch, offset: offset, limit: limit, token: token)
        }
    }

    func remoteWorkflowRunPage(
        for repository: Repository,
        offset: Int,
        limit: Int
    ) async throws -> GitHubWorkflowRunPage {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else {
                throw AzureDevOpsError.invalidOrganization
            }
            return try await azureDevOps.pipelineRunPage(
                repository: repository,
                offset: offset,
                limit: limit,
                organization: organization,
                token: token
            )
        case .github, .none:
            return try await github.workflowRunPage(
                fullName: repository.fullName,
                offset: offset,
                limit: limit,
                token: token
            )
        }
    }

    func remoteCommitDetails(for repository: Repository, commit: GitCommit) async throws -> CommitDetails {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else { throw AzureDevOpsError.invalidOrganization }
            return try await azureDevOps.commitDetails(repository: repository, commit: commit, organization: organization, token: token)
        case .github, .none:
            return try await github.commitDetails(fullName: repository.fullName, commit: commit, token: token)
        }
    }

    func remoteFiles(for repository: Repository, path: String, reference: String?) async throws -> [RemoteFileEntry] {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else { throw AzureDevOpsError.invalidOrganization }
            return try await azureDevOps.files(repository: repository, path: path, reference: reference, organization: organization, token: token)
        case .github, .none:
            return try await github.files(fullName: repository.fullName, path: path, reference: reference, token: token)
        }
    }

    func remoteFileContents(for repository: Repository, path: String, reference: String?) async throws -> String {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else { throw AzureDevOpsError.invalidOrganization }
            return try await azureDevOps.fileContents(repository: repository, path: path, reference: reference, organization: organization, token: token)
        case .github, .none:
            return try await github.fileContents(fullName: repository.fullName, path: path, reference: reference, token: token)
        }
    }

    func remoteFileData(for repository: Repository, path: String, reference: String?) async throws -> Data {
        let token = token(for: repository)
        switch repository.provider {
        case .azureDevOps:
            guard let organization = account(for: repository)?.organization else {
                throw AzureDevOpsError.invalidOrganization
            }
            return try await azureDevOps.fileData(
                repository: repository,
                path: path,
                reference: reference,
                organization: organization,
                token: token
            )
        case .github, .none:
            return try await github.fileData(
                fullName: repository.fullName,
                path: path,
                reference: reference,
                token: token
            )
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
                token: token(for: repository),
                provider: repository.provider
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
        for remote in remoteRepositories {
            let key = "\(remote.provider?.rawValue ?? "remote"):\(remote.id)"
            merged[key] = remote
        }
        for local in localRepositories {
            if let remoteKey = merged.first(where: {
                repositoriesMatch(local: local, remote: $0.value)
            })?.key, var existing = merged[remoteKey] {
                existing.localURL = local.localURL
                merged[remoteKey] = existing
            } else {
                merged["local:\(local.id)"] = local
            }
        }
        repositories = merged.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
        if selectedRepositoryID == nil || !repositories.contains(where: { $0.id == selectedRepositoryID }) {
            selectedRepositoryID = repositories.first?.id
        }
    }

    private func repositoriesMatch(local: Repository, remote: Repository) -> Bool {
        let localIdentity = local.cloneURL.flatMap {
            GitService.remoteRepositoryIdentity(from: $0.absoluteString)
        }
        let remoteIdentity = remote.cloneURL.flatMap {
            GitService.remoteRepositoryIdentity(from: $0.absoluteString)
        }
        if let localIdentity, let remoteIdentity {
            guard localIdentity.provider == remoteIdentity.provider,
                  localIdentity.fullName.caseInsensitiveCompare(remoteIdentity.fullName) == .orderedSame else {
                return false
            }
            if let localOrganization = localIdentity.organization,
               let remoteOrganization = remoteIdentity.organization {
                return localOrganization.caseInsensitiveCompare(remoteOrganization) == .orderedSame
            }
            return true
        }

        guard local.fullName.caseInsensitiveCompare(remote.fullName) == .orderedSame else {
            return false
        }
        if let localProvider = local.provider, let remoteProvider = remote.provider,
           localProvider != remoteProvider {
            return false
        }
        guard local.provider == .azureDevOps || remote.provider == .azureDevOps else {
            return true
        }
        let localOrganization = localIdentity?.organization
        let remoteOrganization = remoteIdentity?.organization
        guard let localOrganization, let remoteOrganization else { return true }
        return localOrganization.caseInsensitiveCompare(remoteOrganization) == .orderedSame
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

    private func migrateLegacyGitHubAccountIfNeeded() {
        guard accounts.isEmpty, !defaults.bool(forKey: Self.accountMigrationDefaultsKey) else { return }
        let token = TokenStore.initialToken().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        let account = SourceControlAccount(
            id: UUID(),
            provider: .github,
            displayName: "GitHub account",
            organization: nil
        )
        accounts = [account]
        SourceControlAccountStore.saveToken(token, for: account.id)
        SourceControlAccountStore.save(accounts, defaults: defaults)
        TokenStore.save("")
        defaults.set(true, forKey: Self.accountMigrationDefaultsKey)
    }
}
