import SwiftUI

struct CommitDiffView: View {
    let diff: String
    let emptyTitle: String
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void

    private var document: DiffDocument {
        DiffDocument(diff)
    }

    var body: some View {
        let document = document

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Label("Diff", systemImage: "plus.forwardslash.minus")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                DiffCountLabel(
                    count: document.addedLineCount,
                    label: "added",
                    color: .green
                )
                DiffCountLabel(
                    count: document.deletedLineCount,
                    label: "deleted",
                    color: .red
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Divider() }
            .modifier(VerticalSplitResizeModifier(
                helpText: "Drag to resize the changed files and diff views",
                onChanged: onResizeChanged,
                onEnded: onResizeEnded
            ))

            Divider()

            if diff.isEmpty {
                CommitDetailsFeedback(
                    title: emptyTitle,
                    systemImage: "doc.text.magnifyingglass"
                )
            } else {
                GeometryReader { geometry in
                    ScrollView([.vertical, .horizontal]) {
                        DiffLinesLayout(
                            minimumWidth: geometry.size.width,
                            minimumHeight: geometry.size.height
                        ) {
                            ForEach(Array(document.lines.enumerated()), id: \.offset) { _, line in
                                DiffLineRow(line: line)
                                    .frame(
                                        minWidth: geometry.size.width,
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .background(line.backgroundColor)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct VerticalSplitResizeModifier: ViewModifier {
    let helpText: String
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        NSCursor.resizeUpDown.set()
                        onChanged(value.translation.height)
                    }
                    .onEnded { value in
                        onEnded(value.translation.height)
                        (isHovered ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                    }
            )
            .onHover { isHovering in
                isHovered = isHovering
                (isHovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
            }
            .onDisappear { NSCursor.arrow.set() }
            .help(helpText)
            .accessibilityLabel(helpText)
    }
}

private struct DiffLinesLayout: Layout {
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: max(minimumWidth, sizes.map(\.width).max() ?? 0),
            height: max(minimumHeight, sizes.reduce(0) { $0 + $1.height })
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY

        for subview in subviews {
            let rowProposal = ProposedViewSize(width: bounds.width, height: nil)
            let rowHeight = subview.sizeThatFits(rowProposal).height
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: rowHeight)
            )
            y += rowHeight
        }
    }
}

private struct DiffCountLabel: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(count) \(label)")
                .monospacedDigit()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(line.borderColor)
                .frame(width: 3)

            Text(line.content.isEmpty ? " " : line.content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line.foregroundStyle)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
        }
    }
}

private struct DiffDocument {
    let lines: [DiffLine]
    let addedLineCount: Int
    let deletedLineCount: Int

    init(_ diff: String) {
        let rawLines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        addedLineCount = rawLines.filter {
            $0.hasPrefix("+") && !$0.hasPrefix("+++")
        }.count
        deletedLineCount = rawLines.filter {
            $0.hasPrefix("-") && !$0.hasPrefix("---")
        }.count

        let visibleLines: ArraySlice<String>
        if let firstHunk = rawLines.firstIndex(where: { $0.hasPrefix("@@") }) {
            visibleLines = rawLines[firstHunk...]
        } else {
            let meaningfulLines = rawLines.drop(while: Self.isPatchMetadata)
            visibleLines = meaningfulLines
        }
        var conflictSide: DiffLine.ConflictSide?
        lines = visibleLines.map { rawLine in
            let markerText = Self.markerText(in: rawLine)
            let line = DiffLine(rawLine, conflictSide: conflictSide, isConflictMarker: markerText != nil)
            if markerText?.hasPrefix("<<<<<<<") == true {
                conflictSide = .current
            } else if markerText?.hasPrefix("=======") == true {
                conflictSide = .incoming
            } else if markerText?.hasPrefix(">>>>>>>") == true {
                conflictSide = nil
            }
            return line
        }
    }

    private static func markerText(in line: String) -> String? {
        let value: String
        if let first = line.first, first == "+" || first == "-" || first == " " {
            value = String(line.dropFirst())
        } else {
            value = line
        }
        return value.hasPrefix("<<<<<<<") || value.hasPrefix("=======") || value.hasPrefix(">>>>>>>")
            ? value
            : nil
    }

    private static func isPatchMetadata(_ line: String) -> Bool {
        line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ")
            || line.hasPrefix("old mode ")
            || line.hasPrefix("new mode ")
            || line.hasPrefix("similarity index ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
            || line.isEmpty
    }
}

private struct DiffLine {
    enum ConflictSide {
        case current
        case incoming
    }

    enum Kind {
        case added
        case deleted
        case hunk
        case context
        case conflictMarker
        case conflictCurrent
        case conflictIncoming
    }

    let content: String
    let kind: Kind

    init(
        _ rawLine: String,
        conflictSide: ConflictSide? = nil,
        isConflictMarker: Bool = false
    ) {
        if isConflictMarker {
            kind = .conflictMarker
            content = rawLine.hasPrefix("+") || rawLine.hasPrefix("-") || rawLine.hasPrefix(" ")
                ? String(rawLine.dropFirst())
                : rawLine
        } else if conflictSide == .current {
            kind = .conflictCurrent
            content = rawLine.hasPrefix("+") || rawLine.hasPrefix("-") || rawLine.hasPrefix(" ")
                ? String(rawLine.dropFirst())
                : rawLine
        } else if conflictSide == .incoming {
            kind = .conflictIncoming
            content = rawLine.hasPrefix("+") || rawLine.hasPrefix("-") || rawLine.hasPrefix(" ")
                ? String(rawLine.dropFirst())
                : rawLine
        } else if rawLine.hasPrefix("+") && !rawLine.hasPrefix("+++") {
            kind = .added
            content = String(rawLine.dropFirst())
        } else if rawLine.hasPrefix("-") && !rawLine.hasPrefix("---") {
            kind = .deleted
            content = String(rawLine.dropFirst())
        } else if rawLine.hasPrefix("@@") {
            kind = .hunk
            content = Self.hunkContext(from: rawLine)
        } else {
            kind = .context
            content = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
        }
    }

    private static func hunkContext(from rawLine: String) -> String {
        guard let closingMarker = rawLine.range(of: "@@", range: rawLine.index(rawLine.startIndex, offsetBy: 2)..<rawLine.endIndex) else {
            return rawLine
        }
        return rawLine[closingMarker.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    var backgroundColor: Color {
        switch kind {
        case .added: Color.green.opacity(0.10)
        case .deleted: Color.red.opacity(0.10)
        case .hunk: Color.gray.opacity(0.12)
        case .conflictMarker: Color.orange.opacity(0.28)
        case .conflictCurrent: Color.blue.opacity(0.14)
        case .conflictIncoming: Color.purple.opacity(0.14)
        case .context: .clear
        }
    }

    var borderColor: Color {
        switch kind {
        case .added: Color.green.opacity(0.75)
        case .deleted: Color.red.opacity(0.75)
        case .conflictMarker: Color.orange
        case .conflictCurrent: Color.blue.opacity(0.8)
        case .conflictIncoming: Color.purple.opacity(0.8)
        case .hunk, .context: .clear
        }
    }

    var foregroundStyle: Color {
        switch kind {
        case .hunk: Color(nsColor: .secondaryLabelColor)
        case .conflictMarker: .orange
        case .added, .deleted, .context, .conflictCurrent, .conflictIncoming:
            Color(nsColor: .labelColor)
        }
    }
}
