import XCTest
@testable import GitExplorer

final class GitServiceTests: XCTestCase {
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

        let feature = try XCTUnwrap(commits.first { $0.message == "Feature commit" })
        XCTAssertTrue(feature.children.contains(head.id))
        let details = try await service.details(for: feature, at: repository)
        XCTAssertTrue(details.changedFiles.contains { $0.contains("feature.txt") })
        XCTAssertTrue(details.diff.contains("feature"))

        try write("dirty\n", to: repository.appendingPathComponent("uncommitted.txt"))
        let status = try await service.status(at: repository)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 0)
        XCTAssertTrue(status.hasChanges)
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
