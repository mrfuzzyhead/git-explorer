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

    private func request(path: String, token: String, accept: String = "application/vnd.github+json") async throws -> Data {
        guard let url = URL(string: "https://api.github.com\(path)") else { throw GitHubError.invalidResponse }
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
