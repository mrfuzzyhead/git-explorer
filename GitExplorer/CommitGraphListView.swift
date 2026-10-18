import AppKit
import SwiftUI

struct CommitGraphList: View {
    let layouts: [CommitLayout]
    let highlightedIDs: Set<String>
    @Binding var hoveredCommitID: String?
    @Binding var selectedCommit: GitCommit?
    let repositoryStatus: RepositoryStatus?
    let workingTreeLayout: CommitLayout?
    let hasMergeConflicts: Bool
    let recentBranches: [String]
    let canManageBranches: Bool
    let onBranchAction: (BranchMenuAction) -> Void
    let canCherryPick: Bool
    let onCherryPick: (GitCommit) -> Void
    let loadedCommitCount: Int
    let hasMoreCommits: Bool
    let loadingMore: Bool
    @Binding var columnWidths: CommitGraphColumnWidths
    let loadMore: () -> Void
    @State private var hoverTarget: CommitHoverTarget?

    var body: some View {
        GeometryReader { geometry in
            let displayedColumnWidths = columnWidths.filling(
                minimumTotalWidth: geometry.size.width
            )

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    CommitGraphColumnHeader(
                        columnWidths: $columnWidths,
                        displayedColumnWidths: displayedColumnWidths
                    )
                    Divider()

                    ScrollView(.vertical) {
                        rows(columnWidths: displayedColumnWidths)
                    }
                }
                .frame(
                    width: displayedColumnWidths.totalWidth,
                    height: geometry.size.height,
                    alignment: .topLeading
                )
            }
        }
    }

    private func rows(columnWidths: CommitGraphColumnWidths) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if let workingTreeLayout, let repositoryStatus {
                HStack(spacing: 0) {
                    ReferenceColumn(width: columnWidths.branchTag) {
                        BranchPill(
                            name: repositoryStatus.branch,
                            divergence: repositoryStatus.divergence(for: repositoryStatus.branch),
                            isCurrent: true,
                            commitID: "HEAD",
                            recentBranches: recentBranches,
                            canManage: canManageBranches,
                            color: GraphPalette.color(for: workingTreeLayout.lane),
                            action: onBranchAction
                        )
                    }

                    LaneCanvas(
                        layout: workingTreeLayout,
                        availableWidth: columnWidths.graph,
                        totalLaneCount: maxLaneCount,
                        isWorkingTree: true
                    )
                    .frame(width: columnWidths.graph, height: rowHeight)

                    WorkingTreeMetadataRow(hasMergeConflicts: hasMergeConflicts)
                        .frame(width: columnWidths.message, height: rowHeight)

                    Color.clear.frame(width: columnWidths.user, height: rowHeight)
                    Color.clear.frame(width: columnWidths.date, height: rowHeight)
                }
                .background(
                    selectedCommit?.id == workingTreeLayout.id
                        ? Color.accentColor.opacity(0.2)
                        : Color.orange.opacity(0.08)
                )
                .contentShape(Rectangle())
                .onTapGesture { selectedCommit = workingTreeLayout.commit }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(hasMergeConflicts ? "Merge conflicts" : "Uncommitted changes") on \(repositoryStatus.branch)"
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(
                    selectedCommit?.id == workingTreeLayout.id ? .isSelected : []
                )
            }

            ForEach(layouts) { layout in
                HStack(spacing: 0) {
                    CommitReferenceColumn(
                        commit: layout.commit,
                        color: GraphPalette.color(for: layout.lane),
                        repositoryStatus: repositoryStatus,
                        width: columnWidths.branchTag,
                        recentBranches: recentBranches,
                        canManageBranches: canManageBranches,
                        onBranchAction: onBranchAction
                    )

                    LaneCanvas(
                        layout: layout,
                        availableWidth: columnWidths.graph,
                        totalLaneCount: maxLaneCount
                    )
                    .frame(width: columnWidths.graph, height: rowHeight)

                    CommitMetadataRow(
                        commit: layout.commit,
                        messageWidth: columnWidths.message,
                        userWidth: columnWidths.user,
                        dateWidth: columnWidths.date
                    )
                    .frame(height: rowHeight)
                }
                .background(rowBackground(for: layout))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    updateHover(for: layout.id, surface: .metadata, phase: phase)
                }
                .onTapGesture { selectedCommit = layout.commit }
                .contextMenu {
                    Button("Cherry-Pick into Checked Out Branch…") {
                        onCherryPick(layout.commit)
                    }
                    .disabled(!canCherryPick || layout.commit.parents.count > 1)
                    if layout.commit.parents.count > 1 {
                        Text("Cherry-picking merge commits is not supported")
                    }
                }
            }

            loadMoreRow
        }
        .frame(width: columnWidths.totalWidth, alignment: .leading)
    }

    private let rowHeight: CGFloat = 36
    private var maxLaneCount: Int {
        max(layouts.map(\.laneCount).max() ?? 1, workingTreeLayout?.laneCount ?? 1)
    }

    @ViewBuilder
    private var loadMoreRow: some View {
        if loadingMore {
            ProgressView("Loading older commits…")
                .frame(width: columnWidths.totalWidth)
                .padding(.vertical)
        } else if hasMoreCommits {
            Button("Load older commits") { loadMore() }
                .buttonStyle(.borderless)
                .frame(width: columnWidths.totalWidth)
                .padding(.vertical)
                .onAppear { loadMore() }
        } else {
            Text("\(loadedCommitCount) commits loaded")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: columnWidths.totalWidth)
                .padding(.vertical)
        }
    }

    private func rowBackground(for layout: CommitLayout) -> Color {
        if selectedCommit?.id == layout.id {
            return Color.accentColor.opacity(0.2)
        }
        if hoveredCommitID == layout.id {
            return Color.accentColor.opacity(0.14)
        }
        if hoveredCommitID != nil, highlightedIDs.contains(layout.id) {
            return Color.accentColor.opacity(0.045)
        }
        if layout.commit.isHead {
            return Color.accentColor.opacity(0.08)
        }
        return .clear
    }

    private func updateHover(
        for commitID: String,
        surface: CommitHoverSurface,
        phase: HoverPhase
    ) {
        let target = CommitHoverTarget(commitID: commitID, surface: surface)
        let event: CommitHoverEvent
        switch phase {
        case .active:
            event = .entered(target)
        case .ended:
            event = .exited(target)
        }
        hoverTarget = CommitHoverState.reduce(current: hoverTarget, event: event)
        hoveredCommitID = hoverTarget?.commitID
    }
}

struct CommitGraphColumnWidths: Equatable {
    var branchTag: CGFloat = 220
    var graph: CGFloat = 120
    var message: CGFloat = 360
    var user: CGFloat = 160
    var date: CGFloat = 110

    private static let branchTagDefaultsKey = "commitGraph.columnWidths.branchTag"
    private static let graphDefaultsKey = "commitGraph.columnWidths.graph"
    private static let messageDefaultsKey = "commitGraph.columnWidths.message"
    private static let userDefaultsKey = "commitGraph.columnWidths.user"
    private static let dateDefaultsKey = "commitGraph.columnWidths.date"

    var totalWidth: CGFloat { branchTag + graph + message + user + date }

    func filling(minimumTotalWidth: CGFloat) -> CommitGraphColumnWidths {
        guard totalWidth < minimumTotalWidth else { return self }

        var widths = self
        widths.message += minimumTotalWidth - totalWidth
        return widths
    }

    static var saved: CommitGraphColumnWidths {
        let fallback = CommitGraphColumnWidths()
        return CommitGraphColumnWidths(
            branchTag: savedWidth(forKey: branchTagDefaultsKey, fallback: fallback.branchTag),
            graph: savedWidth(forKey: graphDefaultsKey, fallback: fallback.graph),
            message: savedWidth(forKey: messageDefaultsKey, fallback: fallback.message),
            user: savedWidth(forKey: userDefaultsKey, fallback: fallback.user),
            date: savedWidth(forKey: dateDefaultsKey, fallback: fallback.date)
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Double(branchTag), forKey: Self.branchTagDefaultsKey)
        defaults.set(Double(graph), forKey: Self.graphDefaultsKey)
        defaults.set(Double(message), forKey: Self.messageDefaultsKey)
        defaults.set(Double(user), forKey: Self.userDefaultsKey)
        defaults.set(Double(date), forKey: Self.dateDefaultsKey)
    }

    private static func savedWidth(forKey key: String, fallback: CGFloat) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return CGFloat(UserDefaults.standard.double(forKey: key))
    }
}

private struct CommitGraphColumnHeader: View {
    @Binding var columnWidths: CommitGraphColumnWidths
    let displayedColumnWidths: CommitGraphColumnWidths

    var body: some View {
        HStack(spacing: 0) {
            header(
                "Branch/tag",
                width: $columnWidths.branchTag,
                displayedWidth: displayedColumnWidths.branchTag,
                minimumWidth: 140
            )
            header(
                "Graph",
                width: $columnWidths.graph,
                displayedWidth: displayedColumnWidths.graph,
                minimumWidth: 70
            )
            header(
                "Message",
                width: $columnWidths.message,
                displayedWidth: displayedColumnWidths.message,
                minimumWidth: 180
            )
            header(
                "User",
                width: $columnWidths.user,
                displayedWidth: displayedColumnWidths.user,
                minimumWidth: 100
            )
            header(
                "Date",
                width: $columnWidths.date,
                displayedWidth: displayedColumnWidths.date,
                minimumWidth: 80
            )
        }
        .frame(height: 28)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private func header(
        _ title: String,
        width: Binding<CGFloat>,
        displayedWidth: CGFloat,
        minimumWidth: CGFloat
    ) -> some View {
        ResizableColumnHeader(
            title: title,
            width: width,
            displayedWidth: displayedWidth,
            minimumWidth: minimumWidth
        )
    }
}

struct ResizableColumnHeader: View {
    let title: String
    @Binding var width: CGFloat
    let displayedWidth: CGFloat
    let minimumWidth: CGFloat
    var leadingPadding: CGFloat = 8
    var trailingPadding: CGFloat = 8
    @State private var dragStartWidth: CGFloat?

    private let resizeHandleWidth: CGFloat = 24

    var body: some View {
        ZStack(alignment: .trailing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, leadingPadding)
                .padding(.trailing, trailingPadding)

            Rectangle()
                .fill(.separator)
                .frame(width: 1)

            Color.clear
                .contentShape(Rectangle())
                .frame(width: resizeHandleWidth)
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartWidth == nil {
                                dragStartWidth = displayedWidth
                            }
                            let proposedWidth = max(
                                minimumWidth,
                                (dragStartWidth ?? width) + value.translation.width
                            )
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                width = proposedWidth
                            }
                        }
                        .onEnded { _ in
                            dragStartWidth = nil
                        }
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        NSCursor.resizeLeftRight.set()
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
                .help("Drag to resize the \(title) column")
                .accessibilityLabel("Resize \(title) column")
        }
        .frame(width: displayedWidth, height: 28)
    }
}

private enum GraphPalette {
    private static let colors: [Color] = [
        .blue, .purple, .orange, .green, .pink, .teal, .yellow, .indigo
    ]

    static func color(for lane: Int) -> Color {
        colors[lane % colors.count]
    }
}

private struct ReferenceColumn<Content: View>: View {
    let width: CGFloat
    let content: Content

    init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) { content }
                .padding(.horizontal, 8)
        }
        .frame(width: width, alignment: .leading)
    }
}

private struct CommitReferenceColumn: View {
    let commit: GitCommit
    let color: Color
    let repositoryStatus: RepositoryStatus?
    let width: CGFloat
    let recentBranches: [String]
    let canManageBranches: Bool
    let onBranchAction: (BranchMenuAction) -> Void

    private var branches: [CommitBranchLabel] {
        CommitReferencePresentation.branchLabels(for: commit.branches)
    }

    var body: some View {
        ReferenceColumn(width: width) {
            ForEach(branches, id: \.actionName) { branch in
                BranchPill(
                    name: branch.name,
                    divergence: repositoryStatus?.divergence(for: branch.actionName),
                    isCurrent: commit.isHead && repositoryStatus?.branch == branch.actionName,
                    includesRemote: branch.includesRemote,
                    isRemote: branch.isRemote,
                    actionName: branch.actionName,
                    commitID: commit.id,
                    recentBranches: recentBranches,
                    canManage: canManageBranches,
                    color: color,
                    action: onBranchAction
                )
            }
            ForEach(commit.tags, id: \.self) { tag in
                TagPill(name: tag, color: color)
            }
        }
    }
}

private struct LaneCanvas: View {
    let layout: CommitLayout
    let availableWidth: CGFloat
    let totalLaneCount: Int
    var isWorkingTree = false
    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let radius: CGFloat = isWorkingTree ? 8 : 5
            let topEdge: CGFloat = -1
            let bottomEdge = size.height + 1
            let connectorStyle = StrokeStyle(
                lineWidth: 2.5,
                lineCap: .round,
                lineJoin: .round
            )
            for lane in layout.passThroughLanes {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: topEdge))
                path.addLine(to: CGPoint(x: x(lane), y: bottomEdge))
                context.stroke(path, with: .color(color(lane)), style: connectorStyle)
            }

            if layout.hasIncomingConnection {
                var incoming = Path()
                incoming.move(to: CGPoint(x: x(layout.lane), y: topEdge))
                incoming.addLine(to: CGPoint(x: x(layout.lane), y: centerY))
                context.stroke(incoming, with: .color(color(layout.lane)), style: connectorStyle)
            }

            for connection in layout.incomingConnections {
                var path = Path()
                let start = CGPoint(x: x(connection.fromLane), y: topEdge)
                let end = CGPoint(x: x(connection.toLane), y: centerY)
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: size.height * 0.28),
                    control2: CGPoint(x: end.x, y: centerY - size.height * 0.28)
                )
                context.stroke(path, with: .color(color(connection.colorLane)), style: connectorStyle)
            }

            for connection in layout.connections {
                var path = Path()
                let startY = isWorkingTree && connection.fromLane == layout.lane
                    ? centerY + radius
                    : centerY
                let start = CGPoint(x: x(connection.fromLane), y: startY)
                let end = CGPoint(x: x(connection.toLane), y: bottomEdge)
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: centerY + size.height * 0.28),
                    control2: CGPoint(x: end.x, y: size.height * 0.72)
                )
                context.stroke(path, with: .color(color(connection.colorLane)), style: connectorStyle)
            }

            let rect = CGRect(
                x: x(layout.lane) - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
            let node = Path(ellipseIn: rect)
            if isWorkingTree {
                context.stroke(
                    node,
                    with: .color(color(layout.lane)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 3])
                )
            } else {
                context.fill(node, with: .color(color(layout.lane)))
            }
            if layout.commit.isHead {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color(layout.lane)), lineWidth: 2)
            }
        }
        .accessibilityLabel("\(isWorkingTree ? "Working tree" : "Commit") graph lane \(layout.lane + 1)")
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneSpacing + 14
    }
    private var laneSpacing: CGFloat {
        guard totalLaneCount > 1 else { return 18 }
        return min(18, max(5, (availableWidth - 28) / CGFloat(totalLaneCount - 1)))
    }
    private func color(_ lane: Int) -> Color { GraphPalette.color(for: lane) }
}

private struct WorkingTreeMetadataRow: View {
    let hasMergeConflicts: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label(
                hasMergeConflicts ? "Merge conflicts" : "Uncommitted changes",
                systemImage: hasMergeConflicts ? "exclamationmark.triangle.fill" : "pencil.and.list.clipboard"
            )
                .fontWeight(.semibold)
                .foregroundStyle(hasMergeConflicts ? Color.orange : Color.primary)
            Spacer(minLength: 8)
        }
        .font(.body)
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommitMetadataRow: View {
    let commit: GitCommit
    let messageWidth: CGFloat
    let userWidth: CGFloat
    let dateWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(commit.message)
                    .fontWeight(.regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if commit.parents.count > 1 {
                    Image(systemName: "arrow.triangle.merge")
                        .help("Merge commit")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: messageWidth, alignment: .leading)

            Text(commit.author)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .frame(width: userWidth, alignment: .leading)

            Text(CommitAgeFormatter.string(for: commit.timestamp))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(width: dateWidth, alignment: .leading)
        }
        .font(.body)
        .foregroundStyle(.secondary)
    }
}

private struct BranchPill: View {
    let name: String
    let divergence: BranchDivergence?
    var isCurrent = false
    var includesRemote = false
    var isRemote = false
    var actionName: String?
    let commitID: String
    let recentBranches: [String]
    var canManage = false
    var color: Color = .blue
    let action: (BranchMenuAction) -> Void

    private var branch: String { actionName ?? name }
    private var canSwitch: Bool {
        canManage && branch != "HEAD" && branch != "Detached HEAD"
    }
    private var canModify: Bool { canSwitch && !isRemote }
    private var mergeTargets: [String] { recentBranches.filter { $0 != branch } }

    var body: some View {
        HStack(spacing: 4) {
            Label(
                name,
                systemImage: isCurrent || name == "HEAD" ? "desktopcomputer" : "arrow.triangle.branch"
            )
            if includesRemote {
                Image(systemName: "icloud.fill")
                    .help("Local and remote branch")
            }
            if let divergence {
                if divergence.ahead > 0 {
                    Text("↑\(divergence.ahead)")
                        .help("\(divergence.ahead) commits ahead")
                }
                if divergence.behind > 0 {
                    Text("↓\(divergence.behind)")
                        .help("\(divergence.behind) commits behind")
                }
            }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
        .contextMenu {
            if canSwitch {
                Button("Switch Working Tree") { action(.switchWorkingTree(branch)) }
                    .disabled(isCurrent)
            }
            if canModify {
                Button("Rename") { action(.rename(branch)) }
                Button("Create branch here") {
                    action(.createBranch(source: branch, commitID: commitID))
                }
                Menu("Merge into") {
                    if mergeTargets.isEmpty {
                        Text("No recent branches")
                    } else {
                        ForEach(mergeTargets, id: \.self) { target in
                            Button(target) { action(.merge(source: branch, target: target)) }
                        }
                    }
                }
            }
        }
        .help(canSwitch ? "Right-click for branch actions" : name)
    }
}

enum BranchMenuAction: Equatable {
    case switchWorkingTree(String)
    case rename(String)
    case createBranch(source: String, commitID: String)
    case merge(source: String, target: String)
}

private struct TagPill: View {
    let name: String
    var color: Color = .orange
    var body: some View {
        Label(name, systemImage: "tag.fill")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.5), lineWidth: 1)
            }
            .foregroundStyle(color)
    }
}
