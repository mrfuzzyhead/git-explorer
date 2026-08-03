import XCTest
@testable import GitExplorer

final class GitServiceTests: XCTestCase {
    func testGitHTTPAuthorizationHeaderUsesBasicTokenCredentials() {
        XCTAssertEqual(
            GitService.gitHTTPAuthorizationHeader(token: "test-token"),
            "Authorization: Basic eC1hY2Nlc3MtdG9rZW46dGVzdC10b2tlbg=="
        )
    }

    func testDiscoversNestedRepositoryAndStopsAtGitRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerTests-\(UUID().uuidString)")
        let repository = root
            .appendingPathComponent("organization")
            .appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.appendingPathComponent("nested/ignored/.git"),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let repositories = try await GitService().discoverRepositories(in: root)
        XCTAssertEqual(repositories.count, 1)
        XCTAssertEqual(repositories.first?.name, "project")
        XCTAssertEqual(
            repositories.first?.localURL?.resolvingSymlinksInPath(),
            repository.resolvingSymlinksInPath()
        )
    }

    func testDetectsInstalledGit() async {
        let availability = await GitService().availability()
        guard case let .available(path, version) = availability else {
            return XCTFail("Expected Git to be available")
        }
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(version.hasPrefix("git version"))
    }

    func testReadsMergeHistoryDecorationsChildrenAndDiff() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }

        try git(["init", "-b", "main"], at: repository)
        try git(["config", "user.name", "Git Explorer Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try write("base\n", to: repository.appendingPathComponent("base.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Base commit"], at: repository)
        try git(["tag", "v1.0.0"], at: repository)

        try git(["checkout", "-b", "feature"], at: repository)
        try write("feature\n", to: repository.appendingPathComponent("feature.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Feature commit"], at: repository)
        try git(["checkout", "main"], at: repository)
        try write("main\n", to: repository.appendingPathComponent("main.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Main commit"], at: repository)
        try git(["merge", "--no-ff", "feature", "-m", "Merge feature"], at: repository)
        try git(["remote", "add", "origin", "https://example.invalid/project.git"], at: repository)
        try git(["update-ref", "refs/remotes/origin/main", "HEAD^1"], at: repository)
        try git(["branch", "--set-upstream-to", "origin/main", "main"], at: repository)

        let service = GitService()
        let commits = try await service.commits(at: repository)
        let head = try XCTUnwrap(commits.first)
        XCTAssertEqual(head.message, "Merge feature")
        XCTAssertEqual(head.parents.count, 2)
        XCTAssertTrue(head.isHead)
        XCTAssertTrue(head.branches.contains("main"))
        XCTAssertTrue(commits.contains { $0.tags.contains("v1.0.0") })

        let firstPage = try await service.commitPage(at: repository, offset: 0, limit: 2)
        XCTAssertEqual(firstPage.commits.count, 2)
        XCTAssertTrue(firstPage.hasMore)
        let secondPage = try await service.commitPage(at: repository, offset: 2, limit: 2)
        XCTAssertEqual(secondPage.commits.count, 2)
        XCTAssertFalse(secondPage.hasMore)
        XCTAssertTrue(Set(firstPage.commits.map(\.id)).isDisjoint(with: secondPage.commits.map(\.id)))

        let feature = try XCTUnwrap(commits.first { $0.message == "Feature commit" })
        XCTAssertTrue(feature.children.contains(head.id))
        let details = try await service.details(for: feature, at: repository)
        XCTAssertTrue(details.changedFiles.contains { $0.contains("feature.txt") })
        XCTAssertTrue(details.diff.contains("feature"))

        try write("dirty\n", to: repository.appendingPathComponent("uncommitted.txt"))
        let status = try await service.status(at: repository)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 0)
        XCTAssertEqual(status.divergence(for: "main"), BranchDivergence(ahead: 2, behind: 0))
        XCTAssertEqual(status.divergence(for: "origin/main"), BranchDivergence(ahead: 0, behind: 2))
        XCTAssertNil(status.divergence(for: "feature"))
        XCTAssertTrue(status.hasChanges)

        try write("base changed\n", to: repository.appendingPathComponent("base.txt"))
        try write("staged\n", to: repository.appendingPathComponent("staged.txt"))
        try git(["add", "staged.txt"], at: repository)
        let workingTreeCommit = GitCommit(
            id: "working-tree",
            parents: [head.id],
            author: "",
            timestamp: Date(),
            message: "Uncommitted changes",
            branches: [],
            tags: [],
            isHead: false
        )
        let workingTreeDetails = try await service.workingTreeDetails(
            for: workingTreeCommit,
            at: repository
        )
        XCTAssertTrue(workingTreeDetails.changedFiles.contains("M\tbase.txt"))
        XCTAssertTrue(workingTreeDetails.changedFiles.contains("A\tstaged.txt"))
        XCTAssertTrue(workingTreeDetails.changedFiles.contains("A\tuncommitted.txt"))
        XCTAssertTrue(workingTreeDetails.fileDiffs["M\tbase.txt"]?.contains("base changed") == true)
        XCTAssertTrue(workingTreeDetails.fileDiffs["A\tstaged.txt"]?.contains("staged") == true)
        XCTAssertTrue(workingTreeDetails.fileDiffs["A\tuncommitted.txt"]?.contains("dirty") == true)
    }

    func testFetchUpdatesRemoteTrackingBranchAndBehindCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerFetchFixture-\(UUID().uuidString)")
        let remote = root.appendingPathComponent("remote.git")
        let source = root.appendingPathComponent("source")
        let checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try git(["init", "--bare"], at: remote)
        try git(["init", "-b", "main"], at: source)
        try git(["config", "user.name", "Git Explorer Tests"], at: source)
        try git(["config", "user.email", "tests@example.invalid"], at: source)
        try write("one\n", to: source.appendingPathComponent("history.txt"))
        try git(["add", "."], at: source)
        try git(["commit", "-m", "First"], at: source)
        try git(["remote", "add", "origin", remote.path], at: source)
        try git(["push", "-u", "origin", "main"], at: source)
        try git(["symbolic-ref", "HEAD", "refs/heads/main"], at: remote)
        try git(["clone", remote.path, checkout.path], at: root)

        try write("two\n", to: source.appendingPathComponent("history.txt"))
        try git(["add", "."], at: source)
        try git(["commit", "-m", "Second"], at: source)
        try git(["push"], at: source)

        let service = GitService()
        let statusBeforeFetch = try await service.status(at: checkout)
        XCTAssertEqual(statusBeforeFetch.behind, 0)
        try await service.fetch(at: checkout)
        let status = try await service.status(at: checkout)
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.behind, 1)
        let pushDestination = await service.pushDestination(at: checkout)
        XCTAssertEqual(pushDestination, "origin/main")
    }

    func testStagesUnstagesIgnoresAndCommitsWorkingTreeFiles() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerCommitFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }

        try git(["init", "-b", "main"], at: repository)
        try git(["config", "user.name", "Git Explorer Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try write("base\n", to: repository.appendingPathComponent("base.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Base"], at: repository)

        try write("changed\n", to: repository.appendingPathComponent("base.txt"))
        try write("new\n", to: repository.appendingPathComponent("new.txt"))
        try write("ignored\n", to: repository.appendingPathComponent("ignored.txt"))

        let service = GitService()
        var state = try await service.workingTreeState(at: repository)
        XCTAssertEqual(Set(state.unstaged.map(\.path)), ["base.txt", "ignored.txt", "new.txt"])
        XCTAssertTrue(state.staged.isEmpty)

        let filesToStage = state.unstaged.filter { $0.path == "base.txt" || $0.path == "new.txt" }
        try await service.stage(filesToStage, at: repository)
        state = try await service.workingTreeState(at: repository)
        XCTAssertEqual(Set(state.staged.map(\.path)), ["base.txt", "new.txt"])
        let stagedDiff = try await service.stagedDiff(at: repository)
        XCTAssertTrue(stagedDiff.contains("changed"))

        let newFile = try XCTUnwrap(state.staged.first { $0.path == "new.txt" })
        try await service.unstage([newFile], at: repository)
        state = try await service.workingTreeState(at: repository)
        XCTAssertEqual(state.staged.map(\.path), ["base.txt"])
        XCTAssertTrue(state.unstaged.contains { $0.path == "new.txt" })

        try await service.addIgnorePatterns(["ignored.txt", "sources/*"], at: repository)
        try await service.addIgnorePatterns(["ignored.txt"], at: repository)
        let ignore = try String(contentsOf: repository.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertEqual(ignore.components(separatedBy: "ignored.txt").count - 1, 1)
        XCTAssertTrue(ignore.contains("sources/*"))

        try await service.commit(message: "Update base file", at: repository)
        let commits = try await service.commits(at: repository)
        XCTAssertEqual(commits.first?.message, "Update base file")
        state = try await service.workingTreeState(at: repository)
        XCTAssertFalse(state.staged.contains { $0.path == "base.txt" })
    }

    func testBuildsIgnoreMenuPatternsFromExactPathToAncestors() {
        XCTAssertEqual(
            CommitCreationView.ignorePatterns(for: "sources/mailpill/project.txt"),
            ["sources/mailpill/project.txt", "sources/mailpill/*", "sources/*"]
        )
        XCTAssertEqual(
            CommitCreationView.ignorePatterns(for: "a/b/c/d/e/f/g/h/file.txt").count,
            7
        )

    }

    func testCommitMessageGeneratorEnforcesSubjectBestPractices() throws {
        let longSubject = "Add a deliberately verbose generated commit subject that runs well beyond the accepted Git subject line character limit"
        let message = try CommitMessageGenerator.bestPracticeMessage(from: "\(longSubject).\n\nExplain the change.")
        let subject = try XCTUnwrap(message.components(separatedBy: .newlines).first)
        XCTAssertLessThanOrEqual(subject.count, CommitMessageGenerator.maximumSubjectCharacters)
        XCTAssertFalse(subject.hasSuffix("."))
        XCTAssertTrue(message.contains("\n\nExplain the change."))
        XCTAssertEqual(try CommitMessageGenerator.bestPracticeMessage(from: "Subject: Update settings."), "Update settings")
        XCTAssertEqual(try CommitMessageGenerator.bestPracticeMessage(from: "update settings."), "Update settings")
    }

    func testRepositoryStateFingerprintTracksCommitsBranchesAndWorkingTree() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerStateFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }

        try git(["init", "-b", "main"], at: repository)
        try git(["config", "user.name", "Git Explorer Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try write("one\n", to: repository.appendingPathComponent("history.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "First"], at: repository)

        let service = GitService()
        let initial = try await service.repositoryStateFingerprint(at: repository)

        try write("dirty\n", to: repository.appendingPathComponent("untracked.txt"))
        let dirty = try await service.repositoryStateFingerprint(at: repository)
        XCTAssertNotEqual(dirty, initial)

        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Second"], at: repository)
        let committed = try await service.repositoryStateFingerprint(at: repository)
        XCTAssertNotEqual(committed, dirty)

        try git(["branch", "feature"], at: repository)
        let branched = try await service.repositoryStateFingerprint(at: repository)
        XCTAssertNotEqual(branched, committed)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            let error = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "GitServiceTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: error
            ])
        }
        return output
    }
}
