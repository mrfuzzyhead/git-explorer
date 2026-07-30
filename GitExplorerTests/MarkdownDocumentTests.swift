import XCTest
@testable import GitExplorer

final class MarkdownDocumentTests: XCTestCase {
    func testRecognizesCommonMarkdownExtensionsCaseInsensitively() {
        XCTAssertTrue(MarkdownDocument.isMarkdownFile(URL(fileURLWithPath: "/tmp/README.md")))
        XCTAssertTrue(MarkdownDocument.isMarkdownFile(URL(fileURLWithPath: "/tmp/guide.MARKDOWN")))
        XCTAssertTrue(MarkdownDocument.isMarkdownFile(URL(fileURLWithPath: "/tmp/notes.mdown")))
        XCTAssertFalse(MarkdownDocument.isMarkdownFile(URL(fileURLWithPath: "/tmp/README.txt")))
    }

    func testParsesGitHubStyleBlocks() {
        let markdown = """
        # Project

        A **useful** [link](https://example.com).

        - First
        - Second

        > Important

        ```swift
        let answer = 42
        ```

        | Name | Value |
        | :--- | ----: |
        | One  | `1`   |
        """

        XCTAssertEqual(
            MarkdownDocument(markdown: markdown).blocks,
            [
                .heading(level: 1, text: "Project"),
                .paragraph("A **useful** [link](https://example.com)."),
                .list([
                    .init(text: "First", number: nil),
                    .init(text: "Second", number: nil)
                ]),
                .quote("Important"),
                .code(language: "swift", contents: "let answer = 42"),
                .table(.init(
                    headers: ["Name", "Value"],
                    alignments: [.leading, .trailing],
                    rows: [["One", "`1`"]]
                ))
            ]
        )
    }

    func testKeepsUnclosedFenceAsCodeUntilEndOfDocument() {
        let document = MarkdownDocument(markdown: """
        ~~~
        one
        two
        """)

        XCTAssertEqual(document.blocks, [.code(language: nil, contents: "one\ntwo")])
    }
}
