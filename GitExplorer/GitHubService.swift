import Foundation
import Security

enum GitHubError: LocalizedError {
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case let .requestFailed(code, message): return "GitHub request failed (\(code)): \(message)"
        }
    }
}

actor GitHubService {
    private struct APIRepository: Decodable {
        let id: Int
        let name: String
        let full_name: String
        let description: String?
        let html_url: URL
        let clone_url: URL
        let default_branch: String
        let `private`: Bool
        let updated_at: Date
        let owner: Owner
        struct Owner: Decodable { let login: String }
    }

    private struct APIOrg: Decodable { let login: String }
    private struct APICommit: Decodable {
        let sha: String
        let commit: Metadata
        let parents: [Parent]

        struct Metadata: Decodable {
            let author: Author?
            let committer: Author?
            let message: String
        }
        struct Author: Decodable {
            let name: String
            let date: Date
        }
        struct Parent: Decodable { let sha: String }
    }
    private struct APICommitDetails: Decodable {
        let files: [File]?
        struct File: Decodable {
            let filename: String
            let status: String
            let patch: String?
        }
    }
    private struct APIContent: Decodable {
        let name: String
        let path: String
        let type: String
        let size: Int
        let html_url: URL?
    }
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    func repositories(token: String) async throws -> [Repository] {
        var apiRepositories: [APIRepository] = []
        for page in 1...20 {
            let data = try await request(
                path: "/user/repos?per_page=100&page=\(page)&sort=updated&affiliation=owner,collaborator,organization_member",
                token: token
            )
            let batch = try decoder.decode([APIRepository].self, from: data)
            apiRepositories.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return apiRepositories.map {
            Repository(
                id: String($0.id),
                name: $0.name,
                fullName: $0.full_name,
                owner: $0.owner.login,
                description: $0.description,
                webURL: $0.html_url,
                cloneURL: $0.clone_url,
                defaultBranch: $0.default_branch,
                isPrivate: $0.private,
                localURL: nil,
                updatedAt: $0.updated_at
            )
        }
    }

    func organizations(token: String) async throws -> [String] {
        var organizations: [APIOrg] = []
        for page in 1...10 {
            let data = try await request(path: "/user/orgs?per_page=100&page=\(page)", token: token)
            let batch = try decoder.decode([APIOrg].self, from: data)
            organizations.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return organizations.map(\.login).sorted()
    }

    func readme(fullName: String, token: String) async throws -> String? {
        do {
            let data = try await request(
                path: "/repos/\(fullName)/readme",
                token: token,
                accept: "application/vnd.github.raw+json"
            )
            return String(data: data, encoding: .utf8)
        } catch GitHubError.requestFailed(404, _) {
            return nil
        }
    }

    func commitPage(
        fullName: String,
        branch: String?,
        offset: Int,
        limit: Int,
        token: String
    ) async throws -> GitCommitPage {
        let pageSize = min(max(limit, 1), 100)
        let page = offset / pageSize + 1
        var query = [
            URLQueryItem(name: "per_page", value: String(pageSize)),
            URLQueryItem(name: "page", value: String(page))
        ]
        if let branch, !branch.isEmpty {
            query.append(URLQueryItem(name: "sha", value: branch))
        }
        let data = try await request(path: "/repos/\(fullName)/commits", query: query, token: token)
        let values = try decoder.decode([APICommit].self, from: data)
        let branchName = branch ?? "HEAD"
        var commits = values.enumerated().map { index, value in
            let author = value.commit.author ?? value.commit.committer
            return GitCommit(
                id: value.sha,
                parents: value.parents.map(\.sha),
                author: author?.name ?? "Unknown",
                timestamp: author?.date ?? .distantPast,
                message: value.commit.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value.commit.message,
                branches: offset == 0 && index == 0 ? [branchName] : [],
                tags: [],
                isHead: offset == 0 && index == 0
            )
        }
        var children: [String: [String]] = [:]
        for commit in commits {
            for parent in commit.parents { children[parent, default: []].append(commit.id) }
        }
        for index in commits.indices { commits[index].children = children[commits[index].id] ?? [] }
        return GitCommitPage(commits: commits, hasMore: values.count == pageSize)
    }

    func commitDetails(fullName: String, commit: GitCommit, token: String) async throws -> CommitDetails {
        let data = try await request(path: "/repos/\(fullName)/commits/\(commit.id)", token: token)
        let value = try decoder.decode(APICommitDetails.self, from: data)
        let files = value.files ?? []
        let changedFiles = files.map { "\($0.status)\t\($0.filename)" }
        let diff = files.map { file in
            let header = "--- \(file.filename)\n+++ \(file.filename)"
            return [header, file.patch ?? "Binary file or patch unavailable."].joined(separator: "\n")
        }.joined(separator: "\n\n")
        return CommitDetails(commit: commit, changedFiles: changedFiles, diff: diff)
    }

    func files(fullName: String, path: String, reference: String?, token: String) async throws -> [RemoteFileEntry] {
        let suffix = path.isEmpty ? "" : "/\(Self.encodedPath(path))"
        let query = reference.map { [URLQueryItem(name: "ref", value: $0)] } ?? []
        let data = try await request(path: "/repos/\(fullName)/contents\(suffix)", query: query, token: token)
        let values = try decoder.decode([APIContent].self, from: data)
        return values.compactMap { value in
            guard value.type == "file" || value.type == "dir" else { return nil }
            return RemoteFileEntry(
                name: value.name,
                path: value.path,
                kind: value.type == "dir" ? .directory : .file,
                size: value.size,
                webURL: value.html_url
            )
        }.sorted {
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func fileContents(fullName: String, path: String, reference: String?, token: String) async throws -> String {
        let encodedPath = Self.encodedPath(path)
        let query = reference.map { [URLQueryItem(name: "ref", value: $0)] } ?? []
        let data = try await request(
            path: "/repos/\(fullName)/contents/\(encodedPath)",
            query: query,
            token: token,
            accept: "application/vnd.github.raw+json"
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw GitHubError.invalidResponse
        }
        return value
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        token: String,
        accept: String = "application/vnd.github+json"
    ) async throws -> Data {
        guard var components = URLComponents(string: "https://api.github.com\(path)") else {
            throw GitHubError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.requestFailed(http.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        return data
    }

    private static func encodedPath(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }
}

enum TokenStore {
    private static let service = "net.fuzzyhead.git"
    private static let account = "github-token"

    static func read() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func initialToken() -> String {
        let keychainToken = read()
        if !keychainToken.isEmpty { return keychainToken }
        if let environmentToken = ProcessInfo.processInfo.environment["GITHUB_PAT"], !environmentToken.isEmpty {
            return environmentToken
        }
#if DEBUG
        return DevelopmentEnvironment.githubToken()
#else
        return ""
#endif
    }

    static func save(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

#if DEBUG
private enum DevelopmentEnvironment {
    static func githubToken() -> String {
        let fileManager = FileManager.default
        var candidates = [URL(fileURLWithPath: fileManager.currentDirectoryPath)]
        var ancestor = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<10 {
            candidates.append(ancestor)
            ancestor.deleteLastPathComponent()
        }

        for directory in candidates {
            let file = directory.appendingPathComponent(".env")
            guard let contents = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "GITHUB_PAT" else {
                    continue
                }
                return parts[1]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return ""
    }
}
#endif
