import Foundation

enum GitServiceError: LocalizedError {
    case failed(arguments: [String], message: String)
    case missing

    var errorDescription: String? {
        switch self {
        case let .failed(arguments, message):
            return "git \(arguments.joined(separator: " ")) failed: \(message)"
        case .missing:
            return "Git is not installed. Install Apple Command Line Tools or Git, then relaunch Git Explorer."
        }
    }
}

actor GitService {
    private let fieldSeparator = "\u{1f}"
    private let recordSeparator = "\u{1e}"
    private let executableURL: URL?

    init() {
        let environmentPath = ProcessInfo.processInfo.environment["GIT_EXECUTABLE"]
        let candidates = [
            environmentPath,
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git"
        ].compactMap { $0 }
        executableURL = candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func availability() -> GitAvailability {
        guard let executableURL else {
            return .missing(message: "Git was not found on this Mac.")
        }
        do {
            let version = try run(["--version"])
            return .available(path: executableURL.path, version: version)
        } catch {
            return .missing(message: error.localizedDescription)
        }
    }

    func discoverRepositories(in directory: URL) throws -> [Repository] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootDepth = directory.standardizedFileURL.pathComponents.count
        let ignoredDirectories: Set<String> = [
            "node_modules", "Pods", "vendor", "DerivedData", "build", "dist"
        ]
        var repositories: [Repository] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            if depth > 3 || ignoredDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                continue
            }
            enumerator.skipDescendants()
            let remote = try? run(["-C", url.path, "remote", "get-url", "origin"])
            let fullName = remote.flatMap(Self.repositoryName(fromRemote:)) ?? url.lastPathComponent
            let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
            repositories.append(Repository(
                id: fullName.lowercased(),
                name: parts.last ?? url.lastPathComponent,
                fullName: fullName,
                owner: parts.count > 1 ? parts[0] : "Local",
                description: nil,
                webURL: remote.flatMap(URL.init(string:)),
                cloneURL: remote.flatMap(URL.init(string:)),
                defaultBranch: nil,
                isPrivate: false,
                localURL: url,
                updatedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ))
        }
        return repositories.sorted {
            $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending
        }
    }

    func status(at repository: URL) throws -> RepositoryStatus {
        let branch = try run(["-C", repository.path, "branch", "--show-current"])
        let porcelain = try run(["-C", repository.path, "status", "--porcelain=v2", "--branch"])
        var result = RepositoryStatus(branch: branch.isEmpty ? "Detached HEAD" : branch)
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("# branch.ab ") {
                for part in line.split(separator: " ") {
                    if part.hasPrefix("+") { result.ahead = Int(part.dropFirst()) ?? 0 }
                    if part.hasPrefix("-") { result.behind = Int(part.dropFirst()) ?? 0 }
                }
            } else if !line.hasPrefix("#") {
                result.hasChanges = true
            }
        }
        return result
    }

    func commits(at repository: URL, limit: Int = 20_000) throws -> [GitCommit] {
        let format = "%H%x1f%P%x1f%an%x1f%aI%x1f%s%x1f%D%x1e"
        let raw = try run([
            "-C", repository.path, "log", "--all", "--topo-order",
            "--date-order", "--max-count=\(limit)", "--pretty=format:\(format)"
        ])
        var commits = raw.split(separator: Character(recordSeparator), omittingEmptySubsequences: true)
            .compactMap { parseCommit(String($0)) }

        var children: [String: [String]] = [:]
        for commit in commits {
            for parent in commit.parents { children[parent, default: []].append(commit.id) }
        }
        for index in commits.indices { commits[index].children = children[commits[index].id] ?? [] }
        return commits
    }

    func readREADME(at repository: URL) throws -> String? {
        let names = ["README.md", "Readme.md", "readme.md", "README"]
        for name in names {
            let url = repository.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        return nil
    }

    func listFiles(at directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ).sorted {
            let leftDirectory = (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let rightDirectory = (try? $1.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if leftDirectory != rightDirectory { return leftDirectory }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    func details(for commit: GitCommit, at repository: URL) throws -> CommitDetails {
        let files = try run([
            "-C", repository.path, "diff-tree", "--no-commit-id", "--name-status", "-r", commit.id
        ]).split(separator: "\n").map(String.init)
        let diff = try run([
            "-C", repository.path, "show", "--format=fuller", "--stat", "--patch", "--no-ext-diff", commit.id
        ])
        return CommitDetails(commit: commit, changedFiles: files, diff: diff)
    }

    func clone(remote: URL, into directory: URL, token: String?) throws {
        var environment: [String: String] = [:]
        if let token, !token.isEmpty {
            environment = [
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "http.extraHeader",
                "GIT_CONFIG_VALUE_0": "Authorization: Bearer \(token)"
            ]
        }
        _ = try run(["clone", remote.absoluteString, directory.path], environment: environment)
    }

    func checkout(branch: String, at repository: URL) throws {
        _ = try run(["-C", repository.path, "checkout", branch])
    }

    func delete(branch: String, at repository: URL) throws {
        _ = try run(["-C", repository.path, "branch", "-d", branch])
    }

    func rename(branch: String, to newName: String, at repository: URL) throws {
        _ = try run(["-C", repository.path, "branch", "-m", branch, newName])
    }

    func compare(branch: String, at repository: URL) throws -> String {
        try run(["-C", repository.path, "diff", "--stat", "--patch", "\(branch)...HEAD"])
    }

    private func parseCommit(_ record: String) -> GitCommit? {
        let fields = record.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: fieldSeparator)
        guard fields.count >= 6 else { return nil }
        let decorations = fields[5].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let tags = decorations.filter { $0.hasPrefix("tag: ") }.map { String($0.dropFirst(5)) }
        let branches = decorations.filter { !$0.hasPrefix("tag: ") }.map { item -> String in
            if let range = item.range(of: " -> ") { return String(item[range.upperBound...]) }
            return item
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        guard let date = parser.date(from: fields[3]) ?? fallback.date(from: fields[3]) else { return nil }
        return GitCommit(
            id: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            author: fields[2],
            timestamp: date,
            message: fields[4],
            branches: branches,
            tags: tags,
            isHead: decorations.contains(where: { $0.hasPrefix("HEAD ->") || $0 == "HEAD" })
        )
    }

    private func run(_ arguments: [String], environment: [String: String] = [:]) throws -> String {
        guard let executableURL else { throw GitServiceError.missing }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw GitServiceError.failed(
                arguments: arguments,
                message: String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repositoryName(fromRemote remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") { value.removeLast(4) }
        if let url = URL(string: value), let host = url.host, host.contains("github") {
            return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        if let colon = value.lastIndex(of: ":"), value.contains("@github") {
            return String(value[value.index(after: colon)...])
        }
        return nil
    }
}
