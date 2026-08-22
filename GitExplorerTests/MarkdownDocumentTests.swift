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

    func testIndentedFenceRemovesMarkdownIndentFromLanguageAndContents() {
        let document = MarkdownDocument(markdown: """
        1. Configure the app:

           ```dotenv
           APP_ORIGIN=http://localhost:3000
           DATABASE_URL=postgresql://localhost/app
           ```
        """)

        XCTAssertEqual(
            document.blocks,
            [
                .list([.init(text: "Configure the app:", number: 1)]),
                .code(
                    language: "dotenv",
                    contents: "APP_ORIGIN=http://localhost:3000\nDATABASE_URL=postgresql://localhost/app"
                )
            ]
        )
    }

    func testParsesCenteredHTMLImageBlock() {
        let document = MarkdownDocument(markdown: """
        <p align="center">
          <img src="frontend/public/favicon.svg" alt="Transfer logo" width="88" height="88">
        </p>

        # Transfer
        """)

        XCTAssertEqual(
            document.blocks,
            [
                .image(.init(
                    source: "frontend/public/favicon.svg",
                    alt: "Transfer logo",
                    width: 88,
                    height: 88,
                    alignment: .center
                )),
                .heading(level: 1, text: "Transfer")
            ]
        )
    }

    func testParsesMermaidFlowchartAsDiagram() throws {
        let document = MarkdownDocument(markdown: """
        ```mermaid
        flowchart LR
            Browser[Browser] -->|HTTPS| Edge[Reverse proxy]
            Edge --> Frontend[Frontend nginx + React]
            Frontend <-->|/socket.io| API[Express API]
            API -->|metadata| PostgreSQL[(PostgreSQL)]
        ```
        """)

        guard case let .mermaid(diagram) = try XCTUnwrap(document.blocks.first) else {
            return XCTFail("Expected a Mermaid diagram block")
        }
        XCTAssertEqual(diagram.direction, .leftToRight)
        XCTAssertEqual(diagram.nodes.map(\.label), [
            "Browser", "Reverse proxy", "Frontend nginx + React", "Express API", "PostgreSQL"
        ])
        XCTAssertEqual(diagram.edges.count, 4)
        XCTAssertEqual(diagram.edges[0].label, "HTTPS")
        XCTAssertTrue(diagram.edges[2].bidirectional)
        XCTAssertEqual(diagram.nodes.last?.shape, .database)
    }
}
