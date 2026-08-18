import AppKit
import SwiftUI

private enum DashboardSectionSelection: String, CaseIterable, Identifiable {
    case recent = "Recent"
    case uncommitted = "Uncommitted"
    case attention = "Attention"

    var id: Self { self }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @State private var report: DashboardStatusReport?
    @State private var reloadID = UUID()
    @State private var sectionSelection = DashboardSectionSelection.recent

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                dashboardHeader

                if model.repositories.isEmpty && !model.isLoading {
                    emptyDashboard
                } else {
                    summaryCards
                    sectionPicker
                    selectedSection
                }
            }
            .padding(24)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: reloadID) { await loadStatuses() }
        .navigationTitle("Git Explorer")
    }

    private var dashboardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.largeTitle.bold())
                Text("A quick view of your repositories and what needs attention.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                reloadID = UUID()
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(report == nil || localRepositories.isEmpty)
            .help("Refresh local working tree status")
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach(DashboardSectionSelection.allCases) { section in
                Button {
                    sectionSelection = section
                } label: {
                    Text(section.rawValue)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 13)
                        .frame(minHeight: 28)
                        .contentShape(Capsule())
                }
                .buttonStyle(ResponsiveButtonStyle(
                    isSelected: sectionSelection == section,
                    shape: .capsule,
                    selectedBackground: Color(nsColor: .windowBackgroundColor)
                ))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(sectionSelection == section ? .isSelected : [])
            }
        }
        .padding(2)
        .background(.quaternary, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard view")
    }

    @ViewBuilder
    private var selectedSection: some View {
        switch sectionSelection {
        case .recent:
            recentRepositories
        case .uncommitted:
            workingTreeSection
        case .attention:
            attentionSection
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            SummaryCard(
                title: "Repositories",
                value: "\(model.repositories.count)",
                detail: repositoryMix,
                icon: "square.stack.3d.up"
            )
            SummaryCard(
                title: "Local",
                value: "\(localRepositories.count)",
                detail: "Available on this Mac",
                icon: "externaldrive"
            )
            SummaryCard(
                title: "Clean",
                value: statusValue(cleanRepositories.count),
                detail: statusDetail("working trees ready"),
                icon: "checkmark.circle",
                tint: .green
            )
            SummaryCard(
                title: "Changes",
                value: statusValue(dirtyRepositories.count),
                detail: statusDetail("need a commit"),
                icon: "pencil.and.list.clipboard",
                tint: dirtyRepositories.isEmpty ? .secondary : .orange
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository summary")
    }

    private var recentRepositories: some View {
        DashboardSection(
            title: "Recent Repositories",
            subtitle: "Most recently updated across local and connected repositories"
        ) {
            if recent.isEmpty {
                sectionEmpty("No repository activity is available yet.", icon: "clock")
            } else {
                VStack(spacing: 0) {
                    ForEach(recent) { repository in
                        RepositoryDashboardRow(
                            repository: repository,
                            status: report?.statuses[repository.id],
                            action: { model.openRepository(repository) }
                        )
                        if repository.id != recent.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var workingTreeSection: some View {
        DashboardSection(
            title: "Uncommitted Changes",
            subtitle: "Local repositories with modified, staged, untracked, or conflicted files"
        ) {
            if localRepositories.isEmpty {
                sectionEmpty("No local repositories are configured.", icon: "externaldrive.badge.questionmark")
            } else if report == nil {
                loadingRow("Checking local working trees…")
            } else if dirtyRepositories.isEmpty {
                sectionEmpty("All checked repositories have clean working trees.", icon: "checkmark.circle.fill", tint: .green)
            } else {
                VStack(spacing: 0) {
                    ForEach(dirtyRepositories) { repository in
                        RepositoryDashboardRow(
                            repository: repository,
                            status: report?.statuses[repository.id],
                            emphasis: .changes,
                            action: { model.openRepository(repository) }
                        )
                        if repository.id != dirtyRepositories.last?.id { Divider() }
                    }
                }
            }

            if let report, !report.errors.isEmpty {
                statusWarning(failedCount: report.errors.count)
            }
        }
    }

    private var attentionSection: some View {
        let repositories = attentionRepositories
        return DashboardSection(
            title: "Attention",
            subtitle: "Branches with conflicts or commits waiting to move"
        ) {
            if localRepositories.isEmpty {
                sectionEmpty("No local repositories are configured.", icon: "externaldrive.badge.questionmark")
            } else if report == nil {
                loadingRow("Checking local working trees…")
            } else if repositories.isEmpty {
                sectionEmpty("No repositories need attention.", icon: "checkmark.circle.fill", tint: .green)
            } else {
                VStack(spacing: 0) {
                    ForEach(repositories) { repository in
                        RepositoryDashboardRow(
                            repository: repository,
                            status: report?.statuses[repository.id],
                            emphasis: .attention,
                            action: { model.openRepository(repository) }
                        )
                        if repository.id != repositories.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private var emptyDashboard: some View {
        ContentUnavailableView {
            Label("No Repositories", systemImage: "square.stack.3d.up.slash")
        } description: {
            Text("Choose a repositories folder or connect an account to build your dashboard.")
        } actions: {
            SettingsLink {
                Text("Open Settings")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private func loadStatuses() async {
        guard !localRepositories.isEmpty else {
            report = DashboardStatusReport()
            return
        }
        guard model.gitAvailability.isAvailable else {
            report = DashboardStatusReport(errors: Dictionary(
                uniqueKeysWithValues: localRepositories.map { ($0.id, "Git is unavailable.") }
            ))
            return
        }
        report = nil
        report = await model.git.dashboardStatuses(for: model.repositories)
    }

    private var localRepositories: [Repository] {
        model.repositories.filter(\.isLocal)
    }

    private var dirtyRepositories: [Repository] {
        localRepositories
            .filter { report?.statuses[$0.id]?.hasChanges == true }
            .sorted(by: dashboardRepositoryOrder)
    }

    private var cleanRepositories: [Repository] {
        localRepositories.filter { report?.statuses[$0.id]?.hasChanges == false }
    }

    private var attentionRepositories: [Repository] {
        localRepositories
            .filter { repository in
                guard let status = report?.statuses[repository.id] else { return false }
                return status.hasMergeConflicts || status.ahead > 0 || status.behind > 0
            }
            .sorted { left, right in
                let leftStatus = report?.statuses[left.id]
                let rightStatus = report?.statuses[right.id]
                if leftStatus?.hasMergeConflicts != rightStatus?.hasMergeConflicts {
                    return leftStatus?.hasMergeConflicts == true
                }
                return dashboardRepositoryOrder(left, right)
            }
    }

    private var recent: [Repository] {
        model.repositories
            .sorted(by: dashboardRepositoryOrder)
            .prefix(6)
            .map { $0 }
    }

    private var repositoryMix: String {
        let remoteOnly = model.repositories.count - localRepositories.count
        return remoteOnly == 0 ? "All available locally" : "\(remoteOnly) remote only"
    }

    private func statusValue(_ value: Int) -> String {
        report == nil ? "—" : "\(value)"
    }

    private func statusDetail(_ suffix: String) -> String {
        guard let report else { return "Checking status…" }
        if report.errors.isEmpty { return suffix }
        return "\(report.errors.count) could not be checked"
    }

    private func dashboardRepositoryOrder(_ left: Repository, _ right: Repository) -> Bool {
        let leftDate = left.updatedAt ?? .distantPast
        let rightDate = right.updatedAt ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return left.fullName.localizedStandardCompare(right.fullName) == .orderedAscending
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func sectionEmpty(_ title: String, icon: String, tint: Color = .secondary) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(tint)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }

    private func statusWarning(failedCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Couldn’t check \(failedCount) local \(failedCount == 1 ? "repository" : "repositories").")
            Spacer()
            Button("Try Again") { reloadID = UUID() }
        }
        .font(.callout)
        .padding(12)
        .background(.orange.opacity(0.09))
        .accessibilityElement(children: .contain)
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value), \(detail)")
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                }
        }
    }
}

private struct RepositoryDashboardRow: View {
    enum Emphasis {
        case normal
        case changes
        case attention
    }

    let repository: Repository
    let status: RepositoryStatus?
    var emphasis = Emphasis.normal
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: leadingIcon)
                .foregroundStyle(leadingTint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(repository.fullName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Label(branch, systemImage: "arrow.triangle.branch")
                    if let updatedAt = repository.updatedAt {
                        Label(CommitAgeFormatter.updatedString(for: updatedAt), systemImage: "clock")
                    }
                    if let status, status.ahead > 0 || status.behind > 0 {
                        Text(divergence(status))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            if emphasis == .changes, status?.hasMergeConflicts == true {
                Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if let url = repository.localURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal \(repository.name) in Finder")
            }
            Button(action: action) {
                Label("Open", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Open \(repository.fullName)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var branch: String {
        status?.branch ?? repository.defaultBranch ?? "Branch unavailable"
    }

    private var leadingIcon: String {
        if status?.hasMergeConflicts == true { return "exclamationmark.triangle.fill" }
        if emphasis == .changes { return "pencil.circle.fill" }
        return repository.isLocal ? "externaldrive.fill" : "cloud.fill"
    }

    private var leadingTint: Color {
        if status?.hasMergeConflicts == true { return .red }
        if emphasis == .changes { return .orange }
        return repository.isLocal ? .green : .secondary
    }

    private func divergence(_ status: RepositoryStatus) -> String {
        [status.ahead > 0 ? "↑\(status.ahead)" : nil, status.behind > 0 ? "↓\(status.behind)" : nil]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
