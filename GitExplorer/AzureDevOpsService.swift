import Foundation

enum AzureDevOpsError: LocalizedError {
    case invalidOrganization
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidOrganization: "Enter an Azure DevOps organization name."
        case .invalidResponse: "Azure DevOps returned an invalid response."
        case let .requestFailed(code, message): "Azure DevOps request failed (\(code)): \(message)"
        }
    }
}

struct AzureDevOpsAccount: Equatable, Sendable {
    let displayName: String
}

actor AzureDevOpsService {
    private struct ConnectionData: Decodable {
        let authenticatedUser: User
        struct User: Decodable { let providerDisplayName: String }
    }

    private struct ListResponse<Value: Decodable>: Decodable { let value: [Value] }
    private struct APIError: Decodable { let message: String? }
    private struct APIRepository: Decodable {
        let id: String
        let name: String
        let defaultBranch: String?
        let remoteUrl: URL?
        let webUrl: URL?
        let project: Project
        struct Project: Decodable {
            let name: String
            let lastUpdateTime: Date?
            let visibility: String?
        }
    }
    private struct APICommit: Decodable {
        let commitId: String
        let author: Identity?
        let committer: Identity?
        let comment: String
        let parents: [String]?
        struct Identity: Decodable {
            let name: String
            let date: Date
        }
    }
    private struct APIRef: Decodable {
        let name: String
        let objectId: String
    }
    private struct APIBuild: Decodable {
        let id: Int64
        let buildNumber: String
        let status: String
        let result: String?
        let queueTime: Date
        let startTime: Date?
        let finishTime: Date?
        let sourceBranch: String?
        let sourceVersion: String?
        let sourceVersionMessage: String?
        let definition: Definition
        let requestedFor: Identity?
        let links: Links?

        struct Definition: Decodable { let name: String }
        struct Identity: Decodable { let displayName: String }
        struct Links: Decodable {
            let web: Link?
            struct Link: Decodable { let href: URL? }
        }

        enum CodingKeys: String, CodingKey {
            case id, buildNumber, status, result, queueTime, startTime, finishTime
            case sourceBranch, sourceVersion, sourceVersionMessage, definition, requestedFor
            case links = "_links"
        }
    }
    private struct APIChange: Decodable {
        let changeType: String
        let item: Item
        struct Item: Decodable { let path: String }
    }
    private struct APIItem: Decodable {
        let path: String
        let isFolder: Bool?
        let size: Int?
        let url: URL?
        let content: String?
    }

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }()

    func account(organization: String, token: String) async throws -> AzureDevOpsAccount {
        let data = try await request(
            organization: organization,
            path: "/_apis/connectionData",
            query: [URLQueryItem(name: "api-version", value: "7.1-preview.1")],
            token: token
        )
        let value = try decoder.decode(ConnectionData.self, from: data)
        return AzureDevOpsAccount(displayName: value.authenticatedUser.providerDisplayName)
    }

    func repositories(organization: String, accountID: UUID, token: String) async throws -> [Repository] {
        let data = try await request(
            organization: organization,
            path: "/_apis/git/repositories",
            query: [URLQueryItem(name: "api-version", value: "7.1")],
            token: token
        )
        let response = try decoder.decode(ListResponse<APIRepository>.self, from: data)
        return response.value.map { value in
            Repository(
                id: "azure:\(organization.lowercased()):\(value.id)",
                name: value.name,
                fullName: "\(value.project.name)/\(value.name)",
                owner: value.project.name,
                description: nil,
                webURL: value.webUrl,
                cloneURL: value.remoteUrl,
                defaultBranch: value.defaultBranch?.replacingOccurrences(of: "refs/heads/", with: ""),
                isPrivate: value.project.visibility?.lowercased() != "public",
                localURL: nil,
                updatedAt: value.project.lastUpdateTime,
                sourceProvider: .azureDevOps,
                sourceAccountID: accountID,
                remoteIdentifier: value.id,
                remoteProject: value.project.name
            )
        }
    }

    func readme(repository: Repository, organization: String, token: String) async throws -> String? {
        for path in ["/README.md", "/README", "/readme.md"] {
            do {
                return try await fileContents(
                    repository: repository,
                    path: path,
                    reference: repository.defaultBranch,
                    organization: organization,
                    token: token
                )
            } catch AzureDevOpsError.requestFailed(404, _) {
                continue
            }
        }
        return nil
    }

    func pipelineRunPage(
        repository: Repository,
        offset: Int,
        limit: Int,
        organization: String,
        token: String
    ) async throws -> GitHubWorkflowRunPage {
        let requestedCount = max(1, offset + limit + 1)
        let data = try await request(
            organization: organization,
            project: repository.remoteProject,
            path: "/_apis/build/builds",
            query: [
                URLQueryItem(name: "repositoryId", value: try repositoryID(repository)),
                URLQueryItem(name: "repositoryType", value: "TfsGit"),
                URLQueryItem(name: "queryOrder", value: "queueTimeDescending"),
                URLQueryItem(name: "$top", value: String(requestedCount)),
                URLQueryItem(name: "api-version", value: "7.1")
            ],
            token: token
        )
        let response = try decoder.decode(ListResponse<APIBuild>.self, from: data)
        let end = min(response.value.count, offset + limit)
        let visibleBuilds = offset < end ? Array(response.value[offset..<end]) : []
        let versionsNeedingTitles = visibleBuilds.compactMap { build in
            build.sourceVersionMessage == nil ? build.sourceVersion : nil
        }
        let commitTitles = await pipelineCommitTitles(
            for: versionsNeedingTitles,
            repositoryID: try repositoryID(repository),
            project: repository.remoteProject,
            organization: organization,
            token: token
        )
        return try pipelineRunPage(
            from: data,
            repository: repository,
            organization: organization,
            offset: offset,
            limit: limit,
            commitTitles: commitTitles
        )
    }

    func pipelineRunPage(
        from data: Data,
        repository: Repository,
        organization: String,
        offset: Int,
        limit: Int,
        commitTitles: [String: String] = [:]
    ) throws -> GitHubWorkflowRunPage {
        let response = try decoder.decode(ListResponse<APIBuild>.self, from: data)
        let end = min(response.value.count, offset + limit)
        let values = offset < end ? response.value[offset..<end] : []
        let runs = values.map { value in
            let sourceVersion = value.sourceVersion.map { String($0.prefix(7)) }
            let commitTitle = value.sourceVersionMessage?
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)
                ?? value.sourceVersion.flatMap { commitTitles[$0] }
                ?? sourceVersion.map { "Commit \($0)" }
                ?? "Build \(value.buildNumber)"
            let status = value.status.lowercased() == "completed" ? "completed" : "in_progress"
            let result = value.result?.lowercased()
            let conclusion = result == "succeeded" || result == "partiallysucceeded" ? "success" : result
            return GitHubWorkflowRun(
                id: value.id,
                workflowTitle: value.definition.name,
                commitTitle: commitTitle,
                commitAuthor: value.requestedFor?.displayName ?? "Unknown",
                branch: value.sourceBranch?
                    .replacingOccurrences(of: "refs/heads/", with: "") ?? "Unknown branch",
                status: status,
                conclusion: conclusion,
                createdAt: value.queueTime,
                startedAt: value.startTime,
                updatedAt: value.finishTime ?? value.startTime ?? value.queueTime,
                webURL: value.links?.web?.href
                    ?? pipelineRunURL(
                        organization: organization,
                        project: repository.remoteProject,
                        buildID: value.id
                    )
            )
        }
        return GitHubWorkflowRunPage(
            runs: runs,
            hasMore: response.value.count > offset + runs.count
        )
    }

    private func pipelineCommitTitles(
        for versions: [String],
        repositoryID: String,
        project: String?,
        organization: String,
        token: String
    ) async -> [String: String] {
        let versions = Array(Set(versions))
        guard !versions.isEmpty else { return [:] }
        var result: [String: String] = [:]
        let maximumConcurrentRequests = 8

        for start in stride(from: 0, to: versions.count, by: maximumConcurrentRequests) {
            let batch = versions[start..<min(start + maximumConcurrentRequests, versions.count)]
            let values = await withTaskGroup(of: (String, String?).self) { group in
                for version in batch {
                    group.addTask {
                        do {
                            let data = try await self.request(
                                organization: organization,
                                project: project,
                                path: "/_apis/git/repositories/\(repositoryID)/commits/\(version)",
                                query: [URLQueryItem(name: "api-version", value: "7.1")],
                                token: token
                            )
                            let commit = try self.decoder.decode(APICommit.self, from: data)
                            let title = commit.comment
                                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                                .first
                                .map(String.init)
                            return (version, title)
                        } catch {
                            return (version, nil)
                        }
                    }
                }
                var values: [(String, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (version, title) in values {
                if let title, !title.isEmpty { result[version] = title }
            }
        }
        return result
    }

    private func pipelineRunURL(organization: String, project: String?, buildID: Int64) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        components.path = "/\(organization)/\(project ?? "")/_build/results"
        components.queryItems = [
            URLQueryItem(name: "buildId", value: String(buildID)),
            URLQueryItem(name: "view", value: "results")
        ]
        return components.url ?? URL(string: "https://dev.azure.com")!
    }

    func commitPage(
        repository: Repository,
        offset: Int,
        limit: Int,
        organization: String,
        token: String
    ) async throws -> GitCommitPage {
        var query = [
            URLQueryItem(name: "searchCriteria.$top", value: String(limit)),
            URLQueryItem(name: "searchCriteria.$skip", value: String(offset)),
            URLQueryItem(name: "api-version", value: "7.1")
        ]
        if let branch = repository.defaultBranch, !branch.isEmpty {
            query.append(URLQueryItem(name: "searchCriteria.itemVersion.version", value: branch))
            query.append(URLQueryItem(name: "searchCriteria.itemVersion.versionType", value: "branch"))
        }
        let commitQuery = query
        let repositoryID = try repositoryID(repository)
        async let commitData = request(
            organization: organization,
            project: repository.remoteProject,
            path: "/_apis/git/repositories/\(repositoryID)/commits",
            query: commitQuery,
            token: token
        )
        async let referenceData = offset == 0
            ? request(
                organization: organization,
                project: repository.remoteProject,
                path: "/_apis/git/repositories/\(repositoryID)/refs",
                query: [
                    URLQueryItem(name: "filter", value: "heads/"),
                    URLQueryItem(name: "api-version", value: "7.1")
                ],
                token: token
            )
            : nil
        let data = try await commitData
        let response = try decoder.decode(ListResponse<APICommit>.self, from: data)
        let references: [APIRef]
        if let data = try await referenceData {
            references = try decoder.decode(ListResponse<APIRef>.self, from: data).value
        } else {
            references = []
        }
        let missingParentIDs = response.value.filter { $0.parents == nil }.map(\.commitId)
        let hydratedParents = try await parents(
            for: missingParentIDs,
            repositoryID: repositoryID,
            project: repository.remoteProject,
            organization: organization,
            token: token
        )
        let branchesByCommit = Dictionary(grouping: references, by: \.objectId).mapValues { references in
            references.map { $0.name.replacingOccurrences(of: "refs/heads/", with: "") }
        }
        var commits = response.value.enumerated().map { index, value in
            let identity = value.author ?? value.committer
            let parts = value.comment.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            var branches = branchesByCommit[value.commitId] ?? []
            if offset == 0, index == 0, branches.isEmpty {
                branches = [repository.defaultBranch ?? "HEAD"]
            }
            return GitCommit(
                id: value.commitId,
                parents: value.parents ?? hydratedParents[value.commitId] ?? [],
                author: identity?.name ?? "Unknown",
                timestamp: identity?.date ?? .distantPast,
                message: parts.first.map(String.init) ?? value.comment,
                description: parts.dropFirst().first.map(String.init),
                branches: branches,
                tags: [],
                isHead: offset == 0 && index == 0
            )
        }
        var children: [String: [String]] = [:]
        for commit in commits { for parent in commit.parents { children[parent, default: []].append(commit.id) } }
        for index in commits.indices { commits[index].children = children[commits[index].id] ?? [] }
        return GitCommitPage(commits: commits, hasMore: response.value.count == limit)
    }

    private func parents(
        for commitIDs: [String],
        repositoryID: String,
        project: String?,
        organization: String,
        token: String
    ) async throws -> [String: [String]] {
        guard !commitIDs.isEmpty else { return [:] }
        var result: [String: [String]] = [:]
        let maximumConcurrentRequests = 8

        for start in stride(from: 0, to: commitIDs.count, by: maximumConcurrentRequests) {
            let batch = commitIDs[start..<min(start + maximumConcurrentRequests, commitIDs.count)]
            let values = try await withThrowingTaskGroup(
                of: (String, [String]).self,
                returning: [(String, [String])].self
            ) { group in
                for commitID in batch {
                    group.addTask {
                        let data = try await self.request(
                            organization: organization,
                            project: project,
                            path: "/_apis/git/repositories/\(repositoryID)/commits/\(commitID)",
                            query: [URLQueryItem(name: "api-version", value: "7.1")],
                            token: token
                        )
                        let commit = try self.decoder.decode(APICommit.self, from: data)
                        return (commitID, commit.parents ?? [])
                    }
                }
                var values: [(String, [String])] = []
                for try await value in group { values.append(value) }
                return values
            }
            for (commitID, parents) in values { result[commitID] = parents }
        }
        return result
    }

    func commitDetails(
        repository: Repository,
        commit: GitCommit,
        organization: String,
        token: String
    ) async throws -> CommitDetails {
        let data = try await request(
            organization: organization,
            project: repository.remoteProject,
            path: "/_apis/git/repositories/\(try repositoryID(repository))/commits/\(commit.id)/changes",
            query: [URLQueryItem(name: "api-version", value: "7.1")],
            token: token
        )
        let response = try decoder.decode(ListResponse<APIChange>.self, from: data)
        let files = response.value.map { "\($0.changeType)\t\($0.item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))" }
        let unavailable = Dictionary(uniqueKeysWithValues: files.map { ($0, "Patch content is not available from Azure DevOps for this change.") })
        return CommitDetails(commit: commit, changedFiles: files, fileDiffs: unavailable)
    }

    func files(
        repository: Repository,
        path: String,
        reference: String?,
        organization: String,
        token: String
    ) async throws -> [RemoteFileEntry] {
        var query = [
            URLQueryItem(name: "scopePath", value: path.isEmpty ? "/" : "/" + path),
            URLQueryItem(name: "recursionLevel", value: "OneLevel"),
            URLQueryItem(name: "includeContentMetadata", value: "true"),
            URLQueryItem(name: "api-version", value: "7.1")
        ]
        if let reference, !reference.isEmpty {
            query.append(URLQueryItem(name: "versionDescriptor.version", value: reference))
            query.append(URLQueryItem(name: "versionDescriptor.versionType", value: "branch"))
        }
        let data = try await request(
            organization: organization,
            project: repository.remoteProject,
            path: "/_apis/git/repositories/\(try repositoryID(repository))/items",
            query: query,
            token: token
        )
        let response = try decoder.decode(ListResponse<APIItem>.self, from: data)
        let requested = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return response.value.compactMap { value in
            let itemPath = value.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard itemPath != requested else { return nil }
            let name = itemPath.split(separator: "/").last.map(String.init) ?? itemPath
            return RemoteFileEntry(
                name: name,
                path: itemPath,
                kind: value.isFolder == true ? .directory : .file,
                size: value.size ?? 0,
                webURL: repository.webURL
            )
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func fileContents(
        repository: Repository,
        path: String,
        reference: String?,
        organization: String,
        token: String
    ) async throws -> String {
        var query = [
            URLQueryItem(name: "path", value: path.hasPrefix("/") ? path : "/" + path),
            URLQueryItem(name: "includeContent", value: "true"),
            URLQueryItem(name: "api-version", value: "7.1")
        ]
        if let reference, !reference.isEmpty {
            query.append(URLQueryItem(name: "versionDescriptor.version", value: reference))
            query.append(URLQueryItem(name: "versionDescriptor.versionType", value: "branch"))
        }
        let data = try await request(
            organization: organization,
            project: repository.remoteProject,
            path: "/_apis/git/repositories/\(try repositoryID(repository))/items",
            query: query,
            token: token
        )
        if let item = try? decoder.decode(APIItem.self, from: data), let content = item.content { return content }
        guard let content = String(data: data, encoding: .utf8) else { throw AzureDevOpsError.invalidResponse }
        return content
    }

    private func repositoryID(_ repository: Repository) throws -> String {
        guard let id = repository.remoteIdentifier, !id.isEmpty else { throw AzureDevOpsError.invalidResponse }
        return id
    }

    private func request(
        organization: String,
        project: String? = nil,
        path: String,
        query: [URLQueryItem],
        token: String
    ) async throws -> Data {
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else { throw AzureDevOpsError.invalidOrganization }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "dev.azure.com"
        components.path = "/\(organization)" + (project.map { "/\($0)" } ?? "") + path
        components.queryItems = query
        guard let url = components.url else { throw AzureDevOpsError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        let credentials = Data(":\(token)".utf8).base64EncodedString()
        urlRequest.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AzureDevOpsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIError.self, from: data).message)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw AzureDevOpsError.requestFailed(http.statusCode, message)
        }
        return data
    }
}
