import Foundation
import SwiftUI

struct MermaidFlowchart: Equatable {
    enum Direction: String, Equatable {
        case leftToRight = "LR"
        case rightToLeft = "RL"
        case topToBottom = "TD"
        case bottomToTop = "BT"
    }

    struct Node: Identifiable, Equatable {
        enum Shape: Equatable {
            case rectangle
            case rounded
            case database
        }

        let id: String
        var label: String
        var shape: Shape
    }

    struct Edge: Equatable {
        let sourceID: String
        let targetID: String
        let label: String?
        let bidirectional: Bool
    }

    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]

    init?(source: String) {
        let lines = source
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }
        let headerParts = header.split(whereSeparator: { $0.isWhitespace })
        guard headerParts.count >= 2,
              ["flowchart", "graph"].contains(headerParts[0].lowercased()),
              let direction = Direction(rawValue: headerParts[1].uppercased()) else { return nil }

        var orderedIDs: [String] = []
        var nodesByID: [String: Node] = [:]
        var edges: [Edge] = []

        for statement in lines.dropFirst() {
            guard let parsedEdge = Self.edge(in: statement),
                  let sourceNode = Self.node(in: parsedEdge.source),
                  let targetNode = Self.node(in: parsedEdge.target) else { continue }

            for node in [sourceNode, targetNode] {
                if nodesByID[node.id] == nil {
                    orderedIDs.append(node.id)
                    nodesByID[node.id] = node
                } else if node.label != node.id {
                    nodesByID[node.id] = node
                }
            }
            edges.append(Edge(
                sourceID: sourceNode.id,
                targetID: targetNode.id,
                label: parsedEdge.label,
                bidirectional: parsedEdge.bidirectional
            ))
        }

        guard !edges.isEmpty else { return nil }
        self.direction = direction
        nodes = orderedIDs.compactMap { nodesByID[$0] }
        self.edges = edges
    }

    private static func edge(
        in statement: String
    ) -> (source: String, target: String, label: String?, bidirectional: Bool)? {
        let operators = ["<-->", "-->"]
        guard let edgeOperator = operators.first(where: statement.contains),
              let operatorRange = statement.range(of: edgeOperator) else { return nil }
        let source = String(statement[..<operatorRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        var remainder = String(statement[operatorRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        var label: String?
        if remainder.hasPrefix("|"),
           let closingPipe = remainder.dropFirst().firstIndex(of: "|") {
            label = String(remainder[remainder.index(after: remainder.startIndex)..<closingPipe])
            remainder = String(remainder[remainder.index(after: closingPipe)...])
                .trimmingCharacters(in: .whitespaces)
        }
        guard !source.isEmpty, !remainder.isEmpty else { return nil }
        return (source, remainder, label, edgeOperator == "<-->")
    }

    private static func node(in expression: String) -> Node? {
        let pattern = #"^([A-Za-z_][A-Za-z0-9_-]*)(?:\[\((.*)\)\]|\[(.*)\]|\((.*)\)|\{(.*)\})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: expression,
                range: NSRange(expression.startIndex..., in: expression)
              ),
              let idRange = Range(match.range(at: 1), in: expression) else { return nil }
        let id = String(expression[idRange])

        for (capture, shape) in [(2, Node.Shape.database), (3, .rectangle), (4, .rounded), (5, .rounded)] {
            if match.range(at: capture).location != NSNotFound,
               let labelRange = Range(match.range(at: capture), in: expression) {
                return Node(id: id, label: String(expression[labelRange]), shape: shape)
            }
        }
        return Node(id: id, label: id, shape: .rectangle)
    }
}

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

    struct ImageBlock: Equatable {
        enum Alignment: Equatable {
            case leading
            case center
            case trailing
        }

        let source: String
        let alt: String
        let width: CGFloat?
        let height: CGFloat?
        let alignment: Alignment
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListItem])
        case quote(String)
        case code(language: String?, contents: String)
        case image(ImageBlock)
        case mermaid(MermaidFlowchart)
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
                let trimmedFenceLine = line.trimmingCharacters(in: .whitespaces)
                let fenceIndent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let language = String(trimmedFenceLine.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    let contentLine = lines[index]
                    let contentIndent = contentLine.prefix(while: { $0 == " " || $0 == "\t" }).count
                    codeLines.append(String(contentLine.dropFirst(min(fenceIndent, contentIndent))))
                    index += 1
                }
                if index < lines.count { index += 1 }
                let contents = codeLines.joined(separator: "\n")
                if language.lowercased() == "mermaid",
                   let diagram = MermaidFlowchart(source: contents) {
                    parsed.append(.mermaid(diagram))
                } else {
                    parsed.append(.code(
                        language: language.isEmpty ? nil : language,
                        contents: contents
                    ))
                }
                continue
            }

            if let image = Self.htmlImage(startingAt: index, lines: lines) {
                parsed.append(.image(image.value))
                index = image.nextIndex
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
            looksLikeHTMLImageStart(line) ||
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

    private static func looksLikeHTMLImageStart(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("<img") || trimmed.hasPrefix("<p")
    }

    private static func htmlImage(
        startingAt index: Int,
        lines: [String]
    ) -> (value: ImageBlock, nextIndex: Int)? {
        guard looksLikeHTMLImageStart(lines[index]) else { return nil }

        let startsParagraph = lines[index]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .hasPrefix("<p")
        var htmlLines: [String] = []
        var nextIndex = index

        while nextIndex < lines.count {
            htmlLines.append(lines[nextIndex])
            nextIndex += 1
            if !startsParagraph || htmlLines.last?.lowercased().contains("</p>") == true {
                break
            }
        }

        let html = htmlLines.joined(separator: "\n")
        guard let imageTag = firstMatch("<img\\b[^>]*>", in: html) else { return nil }
        let attributes = htmlAttributes(in: imageTag)
        guard let source = attributes["src"], !source.isEmpty else { return nil }

        let paragraphAttributes = firstMatch("<p\\b[^>]*>", in: html)
            .map(htmlAttributes(in:)) ?? [:]
        let alignment: ImageBlock.Alignment
        switch paragraphAttributes["align"]?.lowercased() {
        case "center": alignment = .center
        case "right", "trailing": alignment = .trailing
        default: alignment = .leading
        }

        let width = attributes["width"].flatMap(Double.init).map { CGFloat($0) }
        let height = attributes["height"].flatMap(Double.init).map { CGFloat($0) }
        let image = ImageBlock(
            source: source,
            alt: attributes["alt"] ?? "",
            width: width,
            height: height,
            alignment: alignment
        )
        return (value: image, nextIndex: nextIndex)
    }

    private static func firstMatch(_ pattern: String, in source: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(source.startIndex..., in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              let swiftRange = Range(match.range, in: source) else { return nil }
        return String(source[swiftRange])
    }

    private static func htmlAttributes(in tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*([\"'])(.*?)\2"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [:] }

        let range = NSRange(tag.startIndex..., in: tag)
        var attributes: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 3), in: tag) else { continue }
            attributes[String(tag[nameRange]).lowercased()] = String(tag[valueRange])
        }
        return attributes
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
        case let .image(image):
            MarkdownImageView(image: image, baseURL: baseURL)
                .frame(maxWidth: .infinity, alignment: imageAlignment(image.alignment))
        case let .mermaid(diagram):
            MermaidFlowchartView(diagram: diagram)
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

    private func imageAlignment(_ alignment: MarkdownDocument.ImageBlock.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minWidth: 90,
                        maxWidth: 360,
                        alignment: frameAlignment(table.alignments[column])
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(rowBackground(isHeader: isHeader, rowIndex: rowIndex))
                    .overlay(alignment: .trailing) {
                        if column < cells.count - 1 {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.16))
                                .frame(width: 1)
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

private struct MarkdownImageView: View {
    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed
    }

    let image: MarkdownDocument.ImageBlock
    let baseURL: URL?
    @State private var state = LoadState.loading

    private var resolvedURL: URL? {
        if let absolute = URL(string: image.source), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else { return nil }
        if baseURL.isFileURL {
            return baseURL.appendingPathComponent(image.source)
        }

        if baseURL.host?.lowercased() == "github.com" {
            let parts = baseURL.pathComponents.filter { $0 != "/" }
            if parts.count >= 2 {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "raw.githubusercontent.com"
                components.path = "/\(parts[0])/\(parts[1])/HEAD/\(image.source)"
                return components.url
            }
        }
        return baseURL.appendingPathComponent(image.source)
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case let .loaded(nsImage):
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(image.alt.isEmpty ? "README image" : image.alt)
            case .failed:
                Label(
                    image.alt.isEmpty ? "Image unavailable" : image.alt,
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: image.width, height: image.height)
        .task(id: resolvedURL) {
            state = .loading
            guard let url = resolvedURL else {
                state = .failed
                return
            }
            if url.isFileURL {
                state = NSImage(contentsOf: url).map(LoadState.loaded) ?? .failed
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                state = NSImage(data: data).map(LoadState.loaded) ?? .failed
            } catch {
                state = .failed
            }
        }
    }
}

private struct MermaidFlowchartView: View {
    private struct Placement {
        let center: CGPoint
    }

    let diagram: MermaidFlowchart

    private let nodeSize = CGSize(width: 176, height: 56)
    private let alongGap: CGFloat = 88
    private let crossGap: CGFloat = 24
    private let margin: CGFloat = 26

    private var placements: [String: Placement] {
        var ranks = Dictionary(uniqueKeysWithValues: diagram.nodes.map { ($0.id, 0) })
        for _ in 0..<diagram.nodes.count {
            var changed = false
            for edge in diagram.edges where edge.sourceID != edge.targetID {
                let proposed = min((ranks[edge.sourceID] ?? 0) + 1, diagram.nodes.count - 1)
                if proposed > (ranks[edge.targetID] ?? 0) {
                    ranks[edge.targetID] = proposed
                    changed = true
                }
            }
            if !changed { break }
        }

        let maxRank = ranks.values.max() ?? 0
        let grouped = Dictionary(grouping: diagram.nodes) { ranks[$0.id] ?? 0 }
        let maxCrossCount = max(grouped.values.map(\.count).max() ?? 1, 1)
        let horizontal = diagram.direction == .leftToRight || diagram.direction == .rightToLeft
        let crossExtent = horizontal ? nodeSize.height : nodeSize.width
        let totalCross = CGFloat(maxCrossCount) * crossExtent + CGFloat(maxCrossCount - 1) * crossGap
        var result: [String: Placement] = [:]

        for rank in 0...maxRank {
            let nodes = grouped[rank] ?? []
            let groupCross = CGFloat(nodes.count) * crossExtent + CGFloat(max(nodes.count - 1, 0)) * crossGap
            let crossStart = margin + (totalCross - groupCross) / 2
            for (index, node) in nodes.enumerated() {
                let displayedRank: Int
                switch diagram.direction {
                case .rightToLeft, .bottomToTop: displayedRank = maxRank - rank
                default: displayedRank = rank
                }
                let along = margin + (horizontal ? nodeSize.width : nodeSize.height) / 2
                    + CGFloat(displayedRank) * ((horizontal ? nodeSize.width : nodeSize.height) + alongGap)
                let cross = crossStart + crossExtent / 2 + CGFloat(index) * (crossExtent + crossGap)
                result[node.id] = Placement(center: horizontal
                    ? CGPoint(x: along, y: cross)
                    : CGPoint(x: cross, y: along))
            }
        }
        return result
    }

    private var contentSize: CGSize {
        let values = Array(placements.values)
        let maxX = values.map(\.center.x).max() ?? nodeSize.width / 2
        let maxY = values.map(\.center.y).max() ?? nodeSize.height / 2
        return CGSize(
            width: maxX + nodeSize.width / 2 + margin,
            height: maxY + nodeSize.height / 2 + margin
        )
    }

    var body: some View {
        let placements = placements
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for (edgeIndex, edge) in diagram.edges.enumerated() {
                        guard let source = placements[edge.sourceID]?.center,
                              let target = placements[edge.targetID]?.center else { continue }
                        let endpoints = edgeEndpoints(
                            from: source,
                            to: target,
                            parallelOffset: parallelOffset(for: edgeIndex)
                        )
                        var path = Path()
                        path.move(to: endpoints.start)
                        if abs(endpoints.end.x - endpoints.start.x) >= abs(endpoints.end.y - endpoints.start.y) {
                            let middleX = (endpoints.start.x + endpoints.end.x) / 2
                            path.addCurve(
                                to: endpoints.end,
                                control1: CGPoint(x: middleX, y: endpoints.start.y),
                                control2: CGPoint(x: middleX, y: endpoints.end.y)
                            )
                        } else {
                            let middleY = (endpoints.start.y + endpoints.end.y) / 2
                            path.addCurve(
                                to: endpoints.end,
                                control1: CGPoint(x: endpoints.start.x, y: middleY),
                                control2: CGPoint(x: endpoints.end.x, y: middleY)
                            )
                        }
                        context.stroke(path, with: .color(.secondary.opacity(0.65)), lineWidth: 1.5)
                        drawArrowhead(in: &context, tip: endpoints.end, from: endpoints.start)
                        if edge.bidirectional {
                            drawArrowhead(in: &context, tip: endpoints.start, from: endpoints.end)
                        }
                    }
                }

                ForEach(diagram.nodes) { node in
                    if let center = placements[node.id]?.center {
                        MermaidNodeView(node: node)
                            .frame(width: nodeSize.width, height: nodeSize.height)
                            .position(center)
                    }
                }

                ForEach(Array(diagram.edges.enumerated()), id: \.offset) { edgeIndex, edge in
                    if let label = edge.label,
                       let source = placements[edge.sourceID]?.center,
                       let target = placements[edge.targetID]?.center {
                        let offset = parallelOffset(for: edgeIndex)
                        let horizontal = abs(target.x - source.x) >= abs(target.y - source.y)
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.background)
                            .position(
                                x: (source.x + target.x) / 2 + (horizontal ? 0 : offset),
                                y: (source.y + target.y) / 2 + (horizontal ? offset : 0) - 11
                            )
                    }
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.16))
        }
    }

    private func edgeEndpoints(
        from source: CGPoint,
        to target: CGPoint,
        parallelOffset: CGFloat
    ) -> (start: CGPoint, end: CGPoint) {
        if abs(target.x - source.x) >= abs(target.y - source.y) {
            let sign: CGFloat = target.x >= source.x ? 1 : -1
            return (
                CGPoint(x: source.x + sign * nodeSize.width / 2, y: source.y + parallelOffset),
                CGPoint(x: target.x - sign * nodeSize.width / 2, y: target.y + parallelOffset)
            )
        }
        let sign: CGFloat = target.y >= source.y ? 1 : -1
        return (
            CGPoint(x: source.x + parallelOffset, y: source.y + sign * nodeSize.height / 2),
            CGPoint(x: target.x + parallelOffset, y: target.y - sign * nodeSize.height / 2)
        )
    }

    private func parallelOffset(for edgeIndex: Int) -> CGFloat {
        let edge = diagram.edges[edgeIndex]
        let siblings = diagram.edges.indices.filter { index in
            let candidate = diagram.edges[index]
            return (candidate.sourceID == edge.sourceID && candidate.targetID == edge.targetID) ||
                (candidate.sourceID == edge.targetID && candidate.targetID == edge.sourceID)
        }
        guard siblings.count > 1,
              let position = siblings.firstIndex(of: edgeIndex) else { return 0 }
        return (CGFloat(position) - CGFloat(siblings.count - 1) / 2) * 22
    }

    private func drawArrowhead(in context: inout GraphicsContext, tip: CGPoint, from: CGPoint) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length: CGFloat = 8
        let spread: CGFloat = .pi / 6
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(
            x: tip.x - length * cos(angle - spread),
            y: tip.y - length * sin(angle - spread)
        ))
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(
            x: tip.x - length * cos(angle + spread),
            y: tip.y - length * sin(angle + spread)
        ))
        context.stroke(arrow, with: .color(.secondary.opacity(0.8)), lineWidth: 1.5)
    }
}

private struct MermaidNodeView: View {
    let node: MermaidFlowchart.Node

    var body: some View {
        HStack(spacing: 7) {
            if node.shape == .database {
                Image(systemName: "cylinder.split.1x2")
                    .foregroundStyle(.secondary)
            }
            Text(node.label)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: node.shape == .rounded ? 18 : 8))
        .overlay {
            RoundedRectangle(cornerRadius: node.shape == .rounded ? 18 : 8)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.2)
        }
    }
}
