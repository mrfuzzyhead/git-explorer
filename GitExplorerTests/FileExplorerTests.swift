import XCTest
@testable import GitExplorer

final class FileExplorerTests: XCTestCase {
    func testBreadcrumbsStayInsideRepositoryAndBuildEachAncestor() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let directory = root.appendingPathComponent("Sources/Feature")

        XCTAssertEqual(
            ExplorerPath.crumbs(from: root, to: directory).map(\.lastPathComponent),
            ["project", "Sources", "Feature"]
        )
        XCTAssertTrue(ExplorerPath.contains(directory, in: root))
        XCTAssertFalse(ExplorerPath.contains(URL(fileURLWithPath: "/tmp/project-copy"), in: root))
    }

    func testRelativePathUsesRepositoryRoot() {
        let root = URL(fileURLWithPath: "/tmp/project")
        let file = root.appendingPathComponent("Sources/App.swift")

        XCTAssertEqual(ExplorerPath.relativePath(of: file, from: root), "Sources/App.swift")
    }

    func testRecognizesSupportedSourceFilesAndFallsBackForText() {
        XCTAssertEqual(SourceLanguage(url: URL(fileURLWithPath: "/tmp/App.SWIFT")), .swift)
        XCTAssertEqual(SourceLanguage(url: URL(fileURLWithPath: "/tmp/view.tsx")), .typescript)
        XCTAssertEqual(SourceLanguage(url: URL(fileURLWithPath: "/tmp/config.yaml")), .yaml)
        XCTAssertNil(SourceLanguage(url: URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    func testRecognizesImageFilesCaseInsensitively() {
        XCTAssertTrue(ExplorerFileType.isImage(URL(fileURLWithPath: "/tmp/screenshot.PNG")))
        XCTAssertTrue(ExplorerFileType.isImage(URL(fileURLWithPath: "/tmp/photo.jpeg")))
        XCTAssertTrue(ExplorerFileType.isImage(URL(fileURLWithPath: "/tmp/artwork.heic")))
        XCTAssertFalse(ExplorerFileType.isImage(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(ExplorerFileType.isImage(URL(fileURLWithPath: "/tmp/no-extension")))
    }

    func testHighlighterFindsKeywordsStringsCommentsAndNumbersWithoutChangingText() {
        let source = #"let answer = 42 // "not a string""#
        let tokens = SourceSyntaxHighlighter.tokens(in: source, as: .swift)

        XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "let")))
        XCTAssertTrue(tokens.contains(.init(kind: .number, text: "42")))
        XCTAssertTrue(tokens.contains(.init(kind: .comment, text: #"// "not a string""#)))
        XCTAssertEqual(tokens.map(\.text).joined(), source)
    }

    func testLargeFilePreviewLimitsLinesAndPreservesUTF8() {
        let source = (0..<FilePreviewPolicy.previewLineLimit + 10)
            .map { "\($0): café" }
            .joined(separator: "\n")

        let preview = FilePreviewPolicy.limitedPreview(of: source)

        XCTAssertEqual(FilePreviewPolicy.lineCount(in: preview), FilePreviewPolicy.previewLineLimit)
        XCTAssertLessThanOrEqual(preview.utf8.count, FilePreviewPolicy.previewByteLimit)
        XCTAssertTrue(preview.hasSuffix("1999: café"))
    }

    func testLineCountHandlesEmptyTrailingAndUnterminatedLines() {
        XCTAssertEqual(FilePreviewPolicy.lineCount(in: ""), 0)
        XCTAssertEqual(FilePreviewPolicy.lineCount(in: "one\ntwo"), 2)
        XCTAssertEqual(FilePreviewPolicy.lineCount(in: "one\ntwo\n"), 2)
    }

    func testLargeFileLoaderReturnsBoundedPreviewAndFullFileOnRequest() async throws {
        let line = #"    "dependency": { "version": "1.0.0" }"#
        let source = Array(repeating: line, count: 8_204).joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-preview-\(UUID().uuidString).json")
        try source.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = FilePreviewMetadata(byteCount: Int64(source.utf8.count))
        let automatic = try await FilePreviewLoader.read(
            url: url,
            metadata: metadata,
            loadFullFile: false
        )

        XCTAssertTrue(automatic.isTruncated)
        XCTAssertEqual(automatic.totalLineCount, 8_204)
        XCTAssertLessThanOrEqual(automatic.displayedLineCount, FilePreviewPolicy.previewLineLimit)
        XCTAssertLessThanOrEqual(automatic.contents.utf8.count, FilePreviewPolicy.previewByteLimit)
        XCTAssertFalse(automatic.shouldHighlight)

        let full = try await FilePreviewLoader.read(
            url: url,
            metadata: metadata,
            loadFullFile: true
        )

        XCTAssertFalse(full.isTruncated)
        XCTAssertEqual(full.contents, source)
        XCTAssertEqual(full.totalLineCount, 8_204)
        XCTAssertFalse(full.shouldHighlight)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testFileExplorerPaneWidthRestoresAndPersistsThroughAppModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "sourceControlAccounts.didMigrateLegacyGitHub.v1")
        defaults.set(336.0, forKey: "fileExplorer.treePaneWidth")
        defer { defaults.removePersistentDomain(forName: #function) }

        let model = AppModel(defaults: defaults)
        XCTAssertEqual(model.fileExplorerTreePaneWidth, 336)

        model.fileExplorerTreePaneWidth = 248
        XCTAssertEqual(defaults.double(forKey: "fileExplorer.treePaneWidth"), 248)
    }

    func testSearchResultsIgnoreSelectedOrganization() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: "sourceControlAccounts.didMigrateLegacyGitHub.v1")
        defer { defaults.removePersistentDomain(forName: #function) }

        let model = AppModel(defaults: defaults)
        model.repositories = [
            repository(id: "alpha", owner: "Alpha", description: "Shared search term"),
            repository(id: "beta", owner: "Beta", description: "Shared search term"),
            repository(id: "other", owner: "Beta", description: "Unrelated")
        ]
        model.selectedOrganization = "Gamma"
        model.searchText = "search term"

        XCTAssertTrue(model.visibleRepositories.isEmpty)
        XCTAssertEqual(Set(model.searchResults.map(\.id)), ["alpha", "beta"])
        XCTAssertEqual(model.selectedOrganization, "Gamma")
    }

    private func repository(id: String, owner: String, description: String) -> Repository {
        Repository(
            id: id,
            name: id,
            fullName: "\(owner)/\(id)",
            owner: owner,
            description: description,
            webURL: nil,
            cloneURL: nil,
            defaultBranch: nil,
            isPrivate: false,
            localURL: nil,
            updatedAt: nil
        )
    }
}
