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
            let branch = try? run(["-C", url.path, "branch", "--show-current"])
            let latestCommit = try? run(["-C", url.path, "log", "-1", "--format=%cI"])
            repositories.append(Repository(
                id: fullName.lowercased(),
                name: parts.last ?? url.lastPathComponent,
                fullName: fullName,
                owner: parts.count > 1 ? parts[0] : "Local",
                description: nil,
                webURL: Self.githubWebURL(fullName: fullName, remote: remote),
                cloneURL: remote.flatMap(URL.init(string:)),
                defaultBranch: branch?.isEmpty == false ? branch : nil,
                isPrivate: false,
                localURL: url,
                updatedAt: latestCommit.flatMap(Self.gitDate) ??
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
            if line.hasPrefix("# branch.upstream ") {
                result.upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
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

    func repositoryStateFingerprint(at repository: URL) throws -> String {
        let status = try run([
            "-C", repository.path, "status", "--porcelain=v2", "--branch",
            "--untracked-files=normal"
        ])
        let references = try run([
            "-C", repository.path, "for-each-ref", "--sort=refname",
            "--format=%(refname)%00%(objectname)", "refs/heads", "refs/remotes", "refs/tags"
        ])
        return status + "\u{1e}" + references
    }

    func fetch(at repository: URL) async throws {
        guard try hasRemotes(at: repository) else { return }
        let executableURL = executableURL
        _ = try await Task.detached(priority: .utility) {
            try Self.run(
                ["-C", repository.path, "fetch", "--all", "--prune"],
                executableURL: executableURL
            )
        }.value
    }

    func pull(at repository: URL) throws {
        _ = try run(["-C", repository.path, "pull", "--ff-only"])
    }

    func push(at repository: URL) throws {
        let hasUpstream = (try? run([
            "-C", repository.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
        ]).isEmpty == false) == true
        if !hasUpstream,
           let remote = firstRemote(at: repository),
           let branch = try? run(["-C", repository.path, "branch", "--show-current"]),
           !branch.isEmpty {
            _ = try run(["-C", repository.path, "push", "--set-upstream", remote, branch])
            return
        }
        _ = try run(["-C", repository.path, "push"])
    }

    func pushDestination(at repository: URL) -> String? {
        if let upstream = try? run([
            "-C", repository.path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"
        ]), !upstream.isEmpty {
            return upstream
        }
        guard let remote = firstRemote(at: repository) else { return nil }
        if let branch = try? run(["-C", repository.path, "branch", "--show-current"]),
           !branch.isEmpty {
            return "\(remote)/\(branch)"
        }
        return remote
    }

    private func firstRemote(at repository: URL) -> String? {
        guard let remotes = try? run(["-C", repository.path, "remote"]),
              let first = remotes.split(separator: "\n").first else { return nil }
        return String(first)
    }

    func sync(at repository: URL) throws {
        try pull(at: repository)
        try push(at: repository)
    }

    func commits(at repository: URL, limit: Int = 20_000, offset: Int = 0) throws -> [GitCommit] {
        let format = "%H%x1f%P%x1f%an%x1f%aI%x1f%s%x1f%D%x1e"
        let raw = try run([
            "-C", repository.path, "log", "--all", "--topo-order",
            "--date-order", "--skip=\(offset)", "--max-count=\(limit)",
            "--pretty=format:\(format)"
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

    func commitPage(at repository: URL, offset: Int, limit: Int) throws -> GitCommitPage {
        let results = try commits(at: repository, limit: limit + 1, offset: offset)
        return GitCommitPage(
            commits: Array(results.prefix(limit)),
            hasMore: results.count > limit
        )
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
        var fileDiffs: [String: String] = [:]
        for file in files {
            guard let path = file.split(separator: "\t", omittingEmptySubsequences: false).last else {
                continue
            }
            fileDiffs[file] = try run([
                "-C", repository.path, "show", "--format=", "--patch", "--no-ext-diff",
                commit.id, "--", String(path)
            ])
        }
        return CommitDetails(commit: commit, changedFiles: files, fileDiffs: fileDiffs)
    }

    func workingTreeDetails(for commit: GitCommit, at repository: URL) throws -> CommitDetails {
        let rawStatus = try run([
            "-C", repository.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ], trimmingOutput: false)
        let changes = Self.parseWorkingTreeChanges(rawStatus)
        var changedFiles: [String] = []
        var fileDiffs: [String: String] = [:]

        for change in changes {
            let key = "\(change.status)\t\(change.path)"
            changedFiles.append(key)

            if change.isUntracked {
                fileDiffs[key] = try run(
                    [
                        "-C", repository.path, "diff", "--no-index", "--no-ext-diff",
                        "--", "/dev/null", change.path
                    ],
                    allowedTerminationStatuses: [0, 1]
                )
            } else {
                var paths = [change.path]
                if let originalPath = change.originalPath { paths.append(originalPath) }
                fileDiffs[key] = try run([
                    "-C", repository.path, "diff", "HEAD", "--patch", "--no-ext-diff", "--"
                ] + paths)
            }
        }

        return CommitDetails(commit: commit, changedFiles: changedFiles, fileDiffs: fileDiffs)
    }

    func workingTreeState(at repository: URL) throws -> WorkingTreeState {
        let rawStatus = try run([
            "-C", repository.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"
        ], trimmingOutput: false)
        let changes = Self.parseWorkingTreeChanges(rawStatus)
        var staged: [WorkingTreeFile] = []
        var unstaged: [WorkingTreeFile] = []

        for change in changes {
            let indexStatus = change.statusCode.first
            let workTreeStatus = change.statusCode.dropFirst().first
            if indexStatus != " " && indexStatus != "?" {
                staged.append(WorkingTreeFile(
                    path: change.path,
                    originalPath: change.originalPath,
                    status: Self.displayStatus(for: String(indexStatus ?? "M")),
                    area: .staged
                ))
            }
            if workTreeStatus != " " || change.statusCode == "??" {
                unstaged.append(WorkingTreeFile(
                    path: change.path,
                    originalPath: change.originalPath,
                    status: Self.displayStatus(
                        for: change.statusCode == "??" ? "??" : String(workTreeStatus ?? "M")
                    ),
                    area: .unstaged
                ))
            }
        }

        return WorkingTreeState(
            unstaged: unstaged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            staged: staged.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    func stage(_ files: [WorkingTreeFile], at repository: URL) throws {
        let paths = Self.paths(for: files)
        guard !paths.isEmpty else { return }
        _ = try run(["-C", repository.path, "add", "-A", "--"] + paths)
    }

    func unstage(_ files: [WorkingTreeFile], at repository: URL) throws {
        let paths = Self.paths(for: files)
        guard !paths.isEmpty else { return }
        _ = try run(["-C", repository.path, "reset", "--"] + paths)
    }

    func stagedDiff(at repository: URL) throws -> String {
        try run(["-C", repository.path, "diff", "--cached", "--patch", "--no-ext-diff"])
    }

    func commit(message: String, at repository: URL) throws {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        _ = try run(["-C", repository.path, "commit", "-m", value])
    }

    func addIgnorePatterns(_ patterns: [String], at repository: URL) throws {
        let ignoreURL = repository.appendingPathComponent(".gitignore")
        let current = (try? String(contentsOf: ignoreURL, encoding: .utf8)) ?? ""
        let existing = Set(current.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        let additions = patterns.filter { !$0.isEmpty && !existing.contains($0) }
        guard !additions.isEmpty else { return }

        var updated = current
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated.append("\n") }
        updated.append(additions.joined(separator: "\n"))
        updated.append("\n")
        try updated.write(to: ignoreURL, atomically: true, encoding: .utf8)
    }

    func clone(remote: URL, into directory: URL, token: String?) throws {
        var environment: [String: String] = [:]
        if let token, !token.isEmpty {
            environment = [
                "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "http.extraHeader",
                "GIT_CONFIG_VALUE_0": Self.gitHTTPAuthorizationHeader(token: token)
            ]
        }
        _ = try run(["clone", remote.absoluteString, directory.path], environment: environment)
    }

    static func gitHTTPAuthorizationHeader(token: String) -> String {
        let credentials = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return "Authorization: Basic \(credentials)"
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

    private func hasRemotes(at repository: URL) throws -> Bool {
        try !run(["-C", repository.path, "remote"]).isEmpty
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

    private func run(
        _ arguments: [String],
        environment: [String: String] = [:],
        allowedTerminationStatuses: Set<Int32> = [0],
        trimmingOutput: Bool = true
    ) throws -> String {
        try Self.run(
            arguments,
            executableURL: executableURL,
            environment: environment,
            allowedTerminationStatuses: allowedTerminationStatuses,
            trimmingOutput: trimmingOutput
        )
    }

    private nonisolated static func run(
        _ arguments: [String],
        executableURL: URL?,
        environment: [String: String] = [:],
        allowedTerminationStatuses: Set<Int32> = [0],
        trimmingOutput: Bool = true
    ) throws -> String {
        guard let executableURL else { throw GitServiceError.missing }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["GIT_TERMINAL_PROMPT": "0"]) { current, _ in current }
            .merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let outputReader = ProcessOutputReader()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputReader.setOutput(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputReader.setError(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        let (output, error) = outputReader.result
        guard allowedTerminationStatuses.contains(process.terminationStatus) else {
            throw GitServiceError.failed(
                arguments: arguments,
                message: String(decoding: error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let value = String(decoding: output, as: UTF8.self)
        return trimmingOutput ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    private static func parseWorkingTreeChanges(_ value: String) -> [WorkingTreeChange] {
        let records = value.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [WorkingTreeChange] = []
        var index = 0

        while index < records.count {
            let record = records[index]
            guard record.count >= 4 else {
                index += 1
                continue
            }

            let statusCode = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            let isRenameOrCopy = statusCode.contains("R") || statusCode.contains("C")
            let originalPath = isRenameOrCopy && index + 1 < records.count ? records[index + 1] : nil
            changes.append(WorkingTreeChange(
                statusCode: statusCode,
                status: displayStatus(for: statusCode),
                path: path,
                originalPath: originalPath,
                isUntracked: statusCode == "??"
            ))
            index += isRenameOrCopy ? 2 : 1
        }

        return changes
    }

    private static func displayStatus(for code: String) -> String {
        if code == "??" || code.contains("A") { return "A" }
        if code.contains("D") { return "D" }
        if code.contains("R") { return "R" }
        if code.contains("C") { return "C" }
        return "M"
    }

    private static func paths(for files: [WorkingTreeFile]) -> [String] {
        var seen: Set<String> = []
        return files.flatMap { [$0.path, $0.originalPath].compactMap { $0 } }
            .filter { seen.insert($0).inserted }
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

    private static func githubWebURL(fullName: String, remote: String?) -> URL? {
        guard remote.flatMap(repositoryName(fromRemote:)) != nil else { return nil }
        return URL(string: "https://github.com/\(fullName)")
    }

    private static func gitDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct WorkingTreeChange {
    let statusCode: String
    let status: String
    let path: String
    let originalPath: String?
    let isUntracked: Bool
}

private final class ProcessOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func setOutput(_ data: Data) {
        lock.withLock { output = data }
    }

    func setError(_ data: Data) {
        lock.withLock { error = data }
    }

    var result: (Data, Data) {
        lock.withLock { (output, error) }
    }
}
