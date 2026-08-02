import Foundation
import SwiftUI

struct MarkdownDocument: Equatable {
    struct ListItem: Equatable {
        let text: String
        let number: Int?
    }

    struct Table: Equatable {
        enum Alignment: Equatable {
            case leading
            case center
            case trailing
        }

        let headers: [String]
        let alignments: [Alignment]
        let rows: [[String]]
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case quote(String)
        case code(language: String?, contents: String)
        case table(Table)
        case divider
    }

    let blocks: [Block]

    init(markdown: String) {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var parsed: [Block] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = Self.fence(in: line) {
                let language = String(line.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                parsed.append(.code(
                    language: language.isEmpty ? nil : language,
                    contents: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = Self.heading(in: line) {
                parsed.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if Self.isDivider(line) {
                parsed.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let table = Self.table(startingAt: index, lines: lines) {
                parsed.append(.table(table.value))
                index = table.nextIndex
                continue
            }

            if Self.quoteText(in: line) != nil {
                var quoteLines: [String] = []
                while index < lines.count, let text = Self.quoteText(in: lines[index]) {
                    quoteLines.append(text)
                    index += 1
                }
                parsed.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if Self.listItem(in: line) != nil {
                var items: [ListItem] = []
                while index < lines.count, let item = Self.listItem(in: lines[index]) {
                    items.append(item)
                    index += 1
                }
                parsed.append(.list(items))
                continue
            }

            var paragraphLines = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !Self.startsBlock(at: index, lines: lines) {
                paragraphLines.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            parsed.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        blocks = parsed
    }

    static func isMarkdownFile(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd", "mkdn":
            true
        default:
            false
        }
    }

    private static func startsBlock(at index: Int, lines: [String]) -> Bool {
        let line = lines[index]
        return fence(in: line) != nil ||
            heading(in: line) != nil ||
            isDivider(line) ||
            quoteText(in: line) != nil ||
            listItem(in: line) != nil ||
            (index + 1 < lines.count && table(startingAt: index, lines: lines) != nil)
    }

    private static func fence(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
              trimmed.dropFirst(hashes.count).first == " " else { return nil }
        let text = trimmed.dropFirst(hashes.count + 1)
            .trimmingCharacters(in: .whitespaces)
        return (hashes.count, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func quoteText(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func listItem(in line: String) -> ListItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return ListItem(text: String(trimmed.dropFirst(2)), number: nil)
        }

        guard let separator = trimmed.firstIndex(of: "."),
              separator != trimmed.startIndex,
              trimmed.index(after: separator) < trimmed.endIndex,
              trimmed[trimmed.index(after: separator)] == " ",
              let number = Int(trimmed[..<separator]) else { return nil }
        let textStart = trimmed.index(separator, offsetBy: 2)
        return ListItem(text: String(trimmed[textStart...]), number: number)
    }

    private static func table(
        startingAt index: Int,
        lines: [String]
    ) -> (value: Table, nextIndex: Int)? {
        let headers = tableCells(in: lines[index])
        let delimiters = tableCells(in: lines[index + 1])
        guard !headers.isEmpty, headers.count == delimiters.count else { return nil }

        var alignments: [Table.Alignment] = []
        for delimiter in delimiters {
            let trimmed = delimiter.trimmingCharacters(in: .whitespaces)
            let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard core.count >= 3, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (trimmed.hasPrefix(":"), trimmed.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }

        var rows: [[String]] = []
        var nextIndex = index + 2
        while nextIndex < lines.count,
              !lines[nextIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            let cells = tableCells(in: lines[nextIndex])
            guard !cells.isEmpty else { break }
            rows.append(Array((cells + Array(repeating: "", count: headers.count)).prefix(headers.count)))
            nextIndex += 1
        }
        return (Table(headers: headers, alignments: alignments, rows: rows), nextIndex)
    }

    private static func tableCells(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }
        var body = trimmed
        if body.first == "|" { body.removeFirst() }
        if body.last == "|" { body.removeLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

struct MarkdownPreviewView: View {
    let markdown: String
    var baseURL: URL?
    var maximumContentWidth: CGFloat? = 860

    private var document: MarkdownDocument {
        MarkdownDocument(markdown: markdown)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block, baseURL: baseURL)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: maximumContentWidth ?? .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(
                maxWidth: .infinity,
                alignment: maximumContentWidth == nil ? .leading : .center
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownDocument.Block
    let baseURL: URL?

    var body: some View {
        switch block {
        case let .heading(level, text):
            VStack(alignment: .leading, spacing: 8) {
                inlineText(text)
                    .font(headingFont(level))
                    .fontWeight(level < 3 ? .semibold : .medium)
                if level <= 2 { Divider() }
            }
        case let .paragraph(text):
            inlineText(text)
                .font(.body)
                .lineSpacing(4)
        case let .list(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(item.number.map { "\($0)." } ?? "•")
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        inlineText(item.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 8)
        case let .quote(text):
            inlineText(text)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 4)
                }
        case let .code(language, contents):
            VStack(alignment: .leading, spacing: 7) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(contents)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.16))
            }
        case let .table(table):
            MarkdownTableView(table: table, baseURL: baseURL)
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: source, options: options, baseURL: baseURL) {
            return Text(attributed)
        }
        return Text(source)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        case 4: .title3
        default: .headline
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownDocument.Table
    let baseURL: URL?

    var body: some View {
        ScrollView(.horizontal) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.headers, isHeader: true, rowIndex: 0)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, isHeader: false, rowIndex: index + 1)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row(_ cells: [String], isHeader: Bool, rowIndex: Int) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                inlineText(cell)
                    .font(.callout)
                    .fontWeight(isHeader ? .semibold : .regular)
                    .frame(
                        minWidth: 90,
                        maxWidth: 300,
                        alignment: frameAlignment(table.alignments[column])
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(rowBackground(isHeader: isHeader, rowIndex: rowIndex))
                    .overlay(alignment: .trailing) {
                        if column < cells.count - 1 {
                            Divider()
                        }
                    }
            }
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: source, options: options, baseURL: baseURL) {
            return Text(attributed)
        }
        return Text(source)
    }

    private func frameAlignment(_ alignment: MarkdownDocument.Table.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func rowBackground(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader { return Color.secondary.opacity(0.12) }
        return rowIndex.isMultiple(of: 2) ? Color.secondary.opacity(0.045) : .clear
    }
}
