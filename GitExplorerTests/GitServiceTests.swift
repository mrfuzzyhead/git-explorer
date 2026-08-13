import XCTest
@testable import GitExplorer

final class GitServiceTests: XCTestCase {
    func testWorkflowRunPageMapsActionsSummaryAndPagination() async throws {
        let data = Data(#"""
        {
          "total_count": 2,
          "workflow_runs": [
            {
              "id": 42,
              "name": "CI",
              "display_title": "Fallback title",
              "status": "in_progress",
              "conclusion": null,
              "head_branch": "feature/actions",
              "html_url": "https://github.com/example/repo/actions/runs/42",
              "created_at": "2026-08-04T01:00:00Z",
              "run_started_at": "2026-08-04T01:01:00Z",
              "updated_at": "2026-08-04T01:02:00Z",
              "actor": { "login": "trigger-user" },
              "head_commit": {
                "message": "Add Actions tab\n\nShow workflow runs.",
                "author": { "name": "Commit Author" }
              }
            }
          ]
        }
        """#.utf8)

        let page = try await GitHubService().workflowRunPage(from: data, offset: 0)
        let run = try XCTUnwrap(page.runs.first)

        XCTAssertEqual(run.id, 42)
        XCTAssertEqual(run.workflowTitle, "CI")
        XCTAssertEqual(run.commitTitle, "Fallback title")
        XCTAssertEqual(run.commitAuthor, "trigger-user")
        XCTAssertEqual(run.branch, "feature/actions")
        XCTAssertEqual(run.displayStatus, .inProgress)
        XCTAssertTrue(page.hasMore)
    }

    func testWorkflowRunPageUsesDependabotRunIdentityInsteadOfHeadCommit() async throws {
        let data = Data(#"""
        {
          "total_count": 1,
          "workflow_runs": [
            {
              "id": 190,
              "name": "npm_and_yarn in /. for @babel/core",
              "display_title": "Dependabot Updates #190",
              "status": "completed",
              "conclusion": "success",
              "head_branch": "main",
              "html_url": "https://github.com/example/repo/actions/runs/190",
              "created_at": "2026-08-13T20:25:00Z",
              "run_started_at": "2026-08-13T20:25:00Z",
              "updated_at": "2026-08-13T20:25:57Z",
              "actor": { "login": "dependabot" },
              "head_commit": {
                "message": "Enhance adaptive card tools with new integrations",
                "author": { "name": "Bradley Searle" }
              }
            }
          ]
        }
        """#.utf8)

        let page = try await GitHubService().workflowRunPage(from: data, offset: 0)
        let run = try XCTUnwrap(page.runs.first)

        XCTAssertEqual(run.workflowTitle, "npm_and_yarn in /. for @babel/core")
        XCTAssertEqual(run.commitTitle, "Dependabot Updates #190")
        XCTAssertEqual(run.commitAuthor, "dependabot")
    }

    func testWorkflowRunPageFallsBackToHeadCommitWhenRunIdentityIsMissing() async throws {
        let data = Data(#"""
        {
          "total_count": 1,
          "workflow_runs": [
            {
              "id": 43,
              "name": null,
              "display_title": null,
              "status": "completed",
              "conclusion": "success",
              "head_branch": null,
              "html_url": "https://github.com/example/repo/actions/runs/43",
              "created_at": "2026-08-04T01:00:00Z",
              "run_started_at": null,
              "updated_at": "2026-08-04T01:02:00Z",
              "actor": null,
              "head_commit": {
                "message": "Fallback commit title\n\nDetails.",
                "author": { "name": "Fallback Author" }
              }
            }
          ]
        }
        """#.utf8)

        let page = try await GitHubService().workflowRunPage(from: data, offset: 0)
        let run = try XCTUnwrap(page.runs.first)

        XCTAssertEqual(run.commitTitle, "Fallback commit title")
        XCTAssertEqual(run.commitAuthor, "Fallback Author")
    }

    func testAzurePipelineRunPageMapsBuildSummaryAndPagination() async throws {
        let data = Data(#"""
        {
          "count": 2,
          "value": [
            {
              "id": 314,
              "buildNumber": "20260811.4",
              "status": "completed",
              "result": "succeeded",
              "queueTime": "2026-08-11T01:00:00.000Z",
              "startTime": "2026-08-11T01:01:00.000Z",
              "finishTime": "2026-08-11T01:04:00.000Z",
              "sourceBranch": "refs/heads/staging",
              "sourceVersion": "0123456789abcdef",
              "sourceVersionMessage": "Deploy staging\n\nPipeline run.",
              "definition": { "name": "QRY API CI" },
              "requestedFor": { "displayName": "Bradley Searle" },
              "_links": {
                "web": { "href": "https://dev.azure.com/Queensland-Rail/QRY/_build/results?buildId=314" }
              }
            },
            {
              "id": 313,
              "buildNumber": "20260811.3",
              "status": "inProgress",
              "result": null,
              "queueTime": "2026-08-11T00:00:00.000Z",
              "startTime": null,
              "finishTime": null,
              "sourceBranch": "refs/heads/main",
              "sourceVersion": "abcdef0123456789",
              "definition": { "name": "QRY API CI" },
              "requestedFor": { "displayName": "Bradley Searle" },
              "_links": {}
            }
          ]
        }
        """#.utf8)
        let repository = Repository(
            id: "azure:queensland-rail:repo-id",
            name: "QRY-API",
            fullName: "QRY/QRY-API",
            owner: "QRY",
            isPrivate: true,
            sourceProvider: .azureDevOps,
            remoteIdentifier: "repo-id",
            remoteProject: "QRY"
        )

        let page = try await AzureDevOpsService().pipelineRunPage(
            from: data,
            repository: repository,
            organization: "Queensland-Rail",
            offset: 0,
            limit: 1
        )
        let run = try XCTUnwrap(page.runs.first)

        XCTAssertEqual(run.id, 314)
        XCTAssertEqual(run.workflowTitle, "QRY API CI")
        XCTAssertEqual(run.commitTitle, "Deploy staging")
        XCTAssertEqual(run.commitAuthor, "Bradley Searle")
        XCTAssertEqual(run.branch, "staging")
        XCTAssertEqual(run.displayStatus, .complete)
        XCTAssertEqual(run.elapsedTime(), 180)
        XCTAssertTrue(page.hasMore)

        let secondPage = try await AzureDevOpsService().pipelineRunPage(
            from: data,
            repository: repository,
            organization: "Queensland-Rail",
            offset: 1,
            limit: 1,
            commitTitles: ["abcdef0123456789": "Use a readable Azure commit title"]
        )
        XCTAssertEqual(secondPage.runs.first?.commitTitle, "Use a readable Azure commit title")
    }

    func testWorkflowRunDisplayStatusDistinguishesSuccessAndFailure() {
        let base = GitHubWorkflowRun(
            id: 1,
            workflowTitle: "CI",
            commitTitle: "Test",
            commitAuthor: "Author",
            branch: "main",
            status: "completed",
            conclusion: "success",
            createdAt: .distantPast,
            startedAt: .distantPast,
            updatedAt: .now,
            webURL: URL(string: "https://github.com/example/repo/actions/runs/1")!
        )

        XCTAssertEqual(base.displayStatus, .complete)
        XCTAssertEqual(base.elapsedTime(), base.updatedAt.timeIntervalSince(base.startedAt!))
        let failed = GitHubWorkflowRun(
            id: base.id,
            workflowTitle: base.workflowTitle,
            commitTitle: base.commitTitle,
            commitAuthor: base.commitAuthor,
            branch: base.branch,
            status: base.status,
            conclusion: "failure",
            createdAt: base.createdAt,
            startedAt: base.startedAt,
            updatedAt: base.updatedAt,
            webURL: base.webURL
        )
        XCTAssertEqual(failed.displayStatus, .failed)
    }

    func testGitHTTPAuthorizationHeaderUsesBasicTokenCredentials() {
        XCTAssertEqual(
            GitService.gitHTTPAuthorizationHeader(token: "test-token"),
            "Authorization: Basic eC1hY2Nlc3MtdG9rZW46dGVzdC10b2tlbg=="
        )
        XCTAssertEqual(
            GitService.gitHTTPAuthorizationHeader(token: "azure-token", provider: .azureDevOps),
            "Authorization: Basic OmF6dXJlLXRva2Vu"
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

    func testParsesAzureDevOpsHTTPSRemoteIdentity() throws {
        let identity = try XCTUnwrap(GitService.remoteRepositoryIdentity(
            from: "https://example@dev.azure.com/example/My%20Project/_git/My%20Repo"
        ))

        XCTAssertEqual(identity.provider, .azureDevOps)
        XCTAssertEqual(identity.organization, "example")
        XCTAssertEqual(identity.fullName, "My Project/My Repo")
    }

    func testParsesQRYAzureDevOpsRemoteIdentity() throws {
        let identity = try XCTUnwrap(GitService.remoteRepositoryIdentity(
            from: "https://Queensland-Rail@dev.azure.com/Queensland-Rail/QRY/_git/QRY-API"
        ))

        XCTAssertEqual(identity.provider, .azureDevOps)
        XCTAssertEqual(identity.organization, "Queensland-Rail")
        XCTAssertEqual(identity.fullName, "QRY/QRY-API")
    }

    func testParsesAzureDevOpsSSHRemoteIdentity() throws {
        let identity = try XCTUnwrap(GitService.remoteRepositoryIdentity(
            from: "git@ssh.dev.azure.com:v3/example/MyProject/MyRepo"
        ))

        XCTAssertEqual(identity.provider, .azureDevOps)
        XCTAssertEqual(identity.organization, "example")
        XCTAssertEqual(identity.fullName, "MyProject/MyRepo")
    }

    func testParsesLegacyAzureDevOpsRemoteIdentity() throws {
        let identity = try XCTUnwrap(GitService.remoteRepositoryIdentity(
            from: "https://example.visualstudio.com/MyProject/_git/MyRepo"
        ))

        XCTAssertEqual(identity.provider, .azureDevOps)
        XCTAssertEqual(identity.organization, "example")
        XCTAssertEqual(identity.fullName, "MyProject/MyRepo")
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
        try git([
            "commit", "-m", "Feature commit", "-m",
            "Explain why the feature was added.\n\nInclude the implementation context."
        ], at: repository)
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
        XCTAssertEqual(
            feature.description,
            "Explain why the feature was added.\n\nInclude the implementation context."
        )
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
            description: nil,
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

    func testBranchContextMenuOperationsCreateAndMergeBranches() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerBranchActionsFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }

        try git(["init", "-b", "main"], at: repository)
        try git(["config", "user.name", "Git Explorer Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try write("base\n", to: repository.appendingPathComponent("history.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Base"], at: repository)
        let baseCommit = try git(["rev-parse", "HEAD"], at: repository)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let service = GitService()
        try await service.createBranch("feature", at: baseCommit, in: repository)
        try await service.checkout(branch: "feature", at: repository)
        try write("feature\n", to: repository.appendingPathComponent("feature.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Feature"], at: repository)

        let recentBranches = try await service.recentBranches(at: repository)
        XCTAssertEqual(Set(recentBranches), Set(["main", "feature"]))

        try await service.merge(branch: "feature", into: "main", at: repository)
        XCTAssertEqual(
            try git(["branch", "--show-current"], at: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "main"
        )
        XCTAssertEqual(
            try git(["rev-parse", "main"], at: repository),
            try git(["rev-parse", "feature"], at: repository)
        )
    }

    func testMergeConflictsAreDetectedParsedAndResolvedByHunk() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitExplorerConflictFixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: repository) }

        try git(["init", "-b", "main"], at: repository)
        try git(["config", "user.name", "Git Explorer Tests"], at: repository)
        try git(["config", "user.email", "tests@example.invalid"], at: repository)
        try write("heading\nbase value\nending\n", to: repository.appendingPathComponent("conflict.txt"))
        try git(["add", "."], at: repository)
        try git(["commit", "-m", "Base"], at: repository)
        try git(["checkout", "-b", "feature"], at: repository)
        try write("heading\nincoming value\nending\n", to: repository.appendingPathComponent("conflict.txt"))
        try git(["commit", "-am", "Feature"], at: repository)
        try git(["checkout", "main"], at: repository)
        try write("heading\ncurrent value\nending\n", to: repository.appendingPathComponent("conflict.txt"))
        try git(["commit", "-am", "Main"], at: repository)

        let service = GitService()
        do {
            try await service.merge(branch: "feature", into: "main", at: repository)
            XCTFail("Expected the merge to conflict")
        } catch {}

        let status = try await service.status(at: repository)
        XCTAssertTrue(status.hasChanges)
        XCTAssertTrue(status.hasMergeConflicts)
        XCTAssertEqual(status.conflictedFileCount, 1)

        let conflicts = try await service.mergeConflicts(at: repository)
        let file = try XCTUnwrap(conflicts.first)
        let hunk = try XCTUnwrap(file.hunks.first)
        XCTAssertEqual(file.path, "conflict.txt")
        XCTAssertEqual(hunk.current, "current value")
        XCTAssertEqual(hunk.incoming, "incoming value")

        try await service.resolveMergeConflicts([
            MergeConflictResolution(filePath: file.path, choices: [hunk.id: .incoming])
        ], at: repository)
        let resolvedStatus = try await service.status(at: repository)
        XCTAssertFalse(resolvedStatus.hasMergeConflicts)
        XCTAssertEqual(
            try String(contentsOf: repository.appendingPathComponent("conflict.txt"), encoding: .utf8),
            "heading\nincoming value\nending\n"
        )
        XCTAssertEqual(
            try git(["diff", "--name-only", "--cached"], at: repository)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "conflict.txt"
        )
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
