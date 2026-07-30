import SwiftUI

struct CommitGraphView: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository

    @State private var commits: [GitCommit] = []
    @State private var allLayouts: [CommitLayout] = []
    @State private var selectedCommit: GitCommit?
    @State private var hoveredCommitID: String?
    @State private var query = ""
    @State private var branch = "All"
    @State private var author = "All"
    @State private var tag = "All"
    @State private var dateRange = CommitDateRange.all
    @State private var loading = true
    @State private var selectedBranch: String?
    @State private var branchDialogPresented = false
    @State private var renamePresented = false
    @State private var deletePresented = false
    @State private var renamedBranch = ""
    @State private var comparison: String?

    private var layouts: [CommitLayout] {
        allLayouts.filter { layout in
            let commit = layout.commit
            let matchesQuery = query.isEmpty ||
                commit.id.localizedCaseInsensitiveContains(query) ||
                commit.message.localizedCaseInsensitiveContains(query) ||
                commit.author.localizedCaseInsensitiveContains(query) ||
                commit.branches.contains(where: { $0.localizedCaseInsensitiveContains(query) }) ||
                commit.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            let matchesDate = dateRange.cutoff.map { commit.timestamp >= $0 } ?? true
            return matchesQuery && matchesDate &&
                (branch == "All" || commit.branches.contains(branch)) &&
                (author == "All" || commit.author == author) &&
                (tag == "All" || commit.tags.contains(tag))
        }
    }

    private var highlightedIDs: Set<String> {
        guard let hoveredCommitID else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        var result: Set<String> = [hoveredCommitID]
        var pending = [hoveredCommitID]
        while let id = pending.popLast(), let commit = byID[id] {
            for parent in commit.parents where result.insert(parent).inserted { pending.append(parent) }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            graphControls
            Divider()
            if loading {
                ProgressView("Loading commit history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if layouts.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                graphList
            }
        }
        .task { await load() }
        .sheet(item: $selectedCommit) { commit in
            CommitDetailsView(repository: repository, commit: commit)
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: Binding(get: { comparison != nil }, set: { if !$0 { comparison = nil } })) {
            ComparisonView(branch: selectedBranch ?? "", diff: comparison ?? "")
                .frame(minWidth: 760, minHeight: 560)
        }
        .confirmationDialog(
            "Branch \(selectedBranch ?? "")",
            isPresented: $branchDialogPresented,
            titleVisibility: .visible
        ) {
            Button("Checkout") { performBranchAction(.checkout) }
            Button("Compare with HEAD") { performBranchAction(.compare) }
            Button("Rename…") {
                renamedBranch = selectedBranch ?? ""
                renamePresented = true
            }
            Button("Delete…", role: .destructive) { deletePresented = true }
        }
        .alert("Rename Branch", isPresented: $renamePresented) {
            TextField("New branch name", text: $renamedBranch)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { performBranchAction(.rename(renamedBranch)) }
        }
        .confirmationDialog(
            "Delete \(selectedBranch ?? "")?",
            isPresented: $deletePresented,
            titleVisibility: .visible
        ) {
            Button("Delete Branch", role: .destructive) { performBranchAction(.delete) }
        } message: {
            Text("Git will refuse to delete a branch whose work has not been merged.")
        }
    }

    private var graphControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search SHA, message, author, branch, or tag", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                Spacer()
            }
            HStack(spacing: 10) {
                FilterPicker(title: "Branch", allTitle: "All branches", selection: $branch, values: allBranches)
                FilterPicker(title: "Author", allTitle: "All authors", selection: $author, values: allAuthors)
                FilterPicker(title: "Tag", allTitle: "All tags", selection: $tag, values: allTags)
                Picker("Date", selection: $dateRange) {
                    ForEach(CommitDateRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(maxWidth: 150)
                Spacer()
            }
        }
        .padding(10)
    }

    private var graphList: some View {
        SynchronizedCommitLayers(
            layouts: layouts,
            graphWidth: CGFloat(maxLaneCount) * 18 + 24,
            highlightedIDs: highlightedIDs,
            hoveredCommitID: $hoveredCommitID,
            selectedCommit: $selectedCommit,
            onBranchClick: openBranchActions
        )
    }

    private var maxLaneCount: Int { layouts.map(\.laneCount).max() ?? 1 }
    private var allBranches: [String] { Array(Set(commits.flatMap(\.branches))).sorted() }
    private var allAuthors: [String] { Array(Set(commits.map(\.author))).sorted() }
    private var allTags: [String] { Array(Set(commits.flatMap(\.tags))).sorted() }

    private func load() async {
        defer { loading = false }
        guard let url = repository.localURL else { return }
        do {
            commits = try await model.git.commits(at: url)
            allLayouts = GitGraphLayout.make(commits: commits)
        }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func openBranchActions(_ branch: String) {
        guard branch != "HEAD", !branch.hasPrefix("origin/") else { return }
        selectedBranch = branch
        branchDialogPresented = true
    }

    private func performBranchAction(_ action: BranchAction) {
        guard let branch = selectedBranch, let url = repository.localURL else { return }
        Task {
            do {
                switch action {
                case .checkout: try await model.git.checkout(branch: branch, at: url)
                case .compare: comparison = try await model.git.compare(branch: branch, at: url)
                case .delete: try await model.git.delete(branch: branch, at: url)
                case let .rename(newName):
                    try await model.git.rename(branch: branch, to: newName, at: url)
                }
                if action.requiresReload {
                    commits = try await model.git.commits(at: url)
                    allLayouts = GitGraphLayout.make(commits: commits)
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

private enum BranchAction {
    case checkout, compare, delete, rename(String)
    var requiresReload: Bool {
        switch self { case .compare: false; default: true }
    }
}

private enum CommitDateRange: String, CaseIterable, Identifiable {
    case all = "Any date"
    case week = "Past week"
    case month = "Past month"
    case year = "Past year"
    var id: Self { self }
    var cutoff: Date? {
        let days: Int?
        switch self {
        case .all: days = nil
        case .week: days = 7
        case .month: days = 31
        case .year: days = 365
        }
        return days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
    }
}

private struct FilterPicker: View {
    let title: String
    let allTitle: String
    @Binding var selection: String
    let values: [String]

    var body: some View {
        Picker(title, selection: $selection) {
            Text(allTitle).tag("All")
            ForEach(values, id: \.self) { Text($0).tag($0) }
        }
        .frame(maxWidth: 160)
    }
}

private struct SynchronizedCommitLayers: View {
    let layouts: [CommitLayout]
    let graphWidth: CGFloat
    let highlightedIDs: Set<String>
    @Binding var hoveredCommitID: String?
    @Binding var selectedCommit: GitCommit?
    let onBranchClick: (String) -> Void
    @State private var graphPosition = ScrollPosition(edge: .top)
    @State private var hoverTarget: CommitHoverTarget?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(layouts) { layout in
                            LaneCanvas(layout: layout)
                                .frame(width: graphWidth, height: rowHeight)
                                .background(rowBackground(for: layout))
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    updateHover(for: layout.id, surface: .graph, phase: phase)
                                }
                            Divider()
                        }
                    }
                }
                .scrollDisabled(true)
                .scrollPosition($graphPosition)
                .scrollIndicators(.hidden)
                .frame(width: graphWidth)
            }
            .defaultScrollAnchor(.leading)
            .frame(width: min(max(graphWidth, 58), 280))

            Divider()

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(layouts) { layout in
                        CommitMetadataRow(commit: layout.commit, onBranchClick: onBranchClick)
                            .frame(height: rowHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowBackground(for: layout))
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                updateHover(for: layout.id, surface: .metadata, phase: phase)
                            }
                            .onTapGesture { selectedCommit = layout.commit }
                        Divider()
                    }
                }
                .frame(minWidth: 620, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                graphPosition.scrollTo(y: max(0, offset))
            }
        }
    }

    private let rowHeight: CGFloat = 62

    private func rowBackground(for layout: CommitLayout) -> Color {
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

private struct LaneCanvas: View {
    let layout: CommitLayout
    private let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal, .yellow, .indigo]

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            for lane in layout.passThroughLanes {
                var path = Path()
                path.move(to: CGPoint(x: x(lane), y: 0))
                path.addLine(to: CGPoint(x: x(lane), y: size.height))
                context.stroke(path, with: .color(color(lane)), lineWidth: 2.5)
            }

            var incoming = Path()
            incoming.move(to: CGPoint(x: x(layout.lane), y: 0))
            incoming.addLine(to: CGPoint(x: x(layout.lane), y: centerY))
            context.stroke(incoming, with: .color(color(layout.lane)), lineWidth: 2.5)

            for connection in layout.connections {
                var path = Path()
                let start = CGPoint(x: x(connection.fromLane), y: centerY)
                let end = CGPoint(x: x(connection.toLane), y: size.height)
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: centerY + size.height * 0.28),
                    control2: CGPoint(x: end.x, y: size.height * 0.72)
                )
                context.stroke(path, with: .color(color(connection.toLane)), lineWidth: 2.5)
            }

            let radius: CGFloat = layout.commit.isHead ? 7 : 5
            let rect = CGRect(
                x: x(layout.lane) - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fill(Path(ellipseIn: rect), with: .color(color(layout.lane)))
            if layout.commit.isHead {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(color(layout.lane)), lineWidth: 2)
            }
        }
        .accessibilityLabel("Commit graph lane \(layout.lane + 1)")
    }

    private func x(_ lane: Int) -> CGFloat {
        CGFloat(lane) * 18 + 14
    }
    private func color(_ lane: Int) -> Color { colors[lane % colors.count] }
}

private struct CommitMetadataRow: View {
    let commit: GitCommit
    let onBranchClick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(commit.message).fontWeight(commit.isHead ? .semibold : .regular).lineLimit(1)
                ForEach(commit.branches, id: \.self) { BranchPill(name: $0, action: onBranchClick) }
                ForEach(commit.tags, id: \.self) { TagPill(name: $0) }
            }
            HStack(spacing: 10) {
                Text(commit.author)
                Text(commit.timestamp, style: .relative)
                Text(commit.abbreviatedID).monospaced()
                if commit.parents.count > 1 {
                    Label("Merge", systemImage: "arrow.triangle.merge").labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BranchPill: View {
    let name: String
    let action: (String) -> Void
    var body: some View {
        Button { action(name) } label: {
            Label(name, systemImage: name == "HEAD" ? "location.fill" : "arrow.triangle.branch")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.blue.opacity(0.14), in: Capsule())
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
    }
}

private struct ComparisonView: View {
    @Environment(\.dismiss) private var dismiss
    let branch: String
    let diff: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(branch) compared with HEAD").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Text(diff.isEmpty ? "No differences." : diff)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }
}

private struct TagPill: View {
    let name: String
    var body: some View {
        Label(name, systemImage: "tag.fill")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(.orange)
    }
}

private struct CommitDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let repository: Repository
    let commit: GitCommit
    @State private var details: CommitDetails?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(commit.message).font(.title2.bold())
                    Text(commit.id).font(.caption.monospaced()).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if let details {
                VSplitView {
                    List {
                        Section("Commit") {
                            LabeledContent("Author", value: commit.author)
                            LabeledContent("Date") { Text(commit.timestamp.formatted()) }
                            LabeledContent("Parents", value: commit.parents.joined(separator: ", "))
                            LabeledContent("Children", value: commit.children.joined(separator: ", "))
                        }
                        Section("Changed files") {
                            ForEach(details.changedFiles, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                        }
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(details.diff)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            } else {
                ProgressView("Loading commit details…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            guard let url = repository.localURL else { return }
            do { details = try await model.git.details(for: commit, at: url) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }
}
