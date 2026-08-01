import SwiftUI

struct RepositorySidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var collapsedOwners: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            controls
            repositoryTools
            List(selection: $model.selectedRepositoryID) {
                ForEach(groupedOwners, id: \.owner) { group in
                    DisclosureGroup(
                        isExpanded: ownerExpansionBinding(for: group.owner),
                        content: {
                            ForEach(group.repositories) { repository in
                                RepositoryRow(repository: repository)
                                    .tag(repository.id)
                            }
                        },
                        label: {
                            Text(group.owner)
                                .font(.headline)
                        }
                    )
                    .accessibilityLabel(group.owner)
                    .accessibilityHint("Collapse or expand this organization")
                }
            }
            .overlay {
                if model.isLoading {
                    PaneLoadingView(
                        model.repositories.isEmpty ? "Loading repositories…" : "Refreshing repositories…"
                    )
                    .background(.regularMaterial)
                } else if model.visibleRepositories.isEmpty {
                    if model.repositories.isEmpty {
                        ContentUnavailableView(
                            "No Repositories",
                            systemImage: "externaldrive.badge.questionmark",
                            description: Text("Choose a repositories folder or connect GitHub in Settings.")
                        )
                    } else {
                        ContentUnavailableView.search(text: model.searchText)
                    }
                }
            }
        }
        .navigationTitle("Repositories")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Organization", selection: $model.selectedOrganization) {
                Text("All organizations").tag("All")
                ForEach(model.organizations, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()

            Picker("Repository scope", selection: $model.repositoryFilter) {
                ForEach(RepositoryFilter.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(10)
    }

    private var repositoryTools: some View {
        HStack(spacing: 8) {
            TextField("Search repositories", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
            .help("Refresh repositories")
            .accessibilityLabel("Refresh repositories")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func ownerExpansionBinding(for owner: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedOwners.contains(owner) },
            set: { isExpanded in
                if isExpanded {
                    collapsedOwners.remove(owner)
                } else {
                    collapsedOwners.insert(owner)
                }
            }
        )
    }

    private var groupedOwners: [(owner: String, repositories: [Repository])] {
        Dictionary(grouping: model.visibleRepositories, by: \.owner)
            .map { ($0.key, $0.value) }
            .sorted { $0.owner.localizedStandardCompare($1.owner) == .orderedAscending }
    }
}

private struct RepositoryRow: View {
    let repository: Repository

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repository.isLocal ? "externaldrive.fill" : "cloud.fill")
                .foregroundStyle(repository.isLocal ? .green : .secondary)
                .frame(width: 18)
            HStack {
                Text(repository.name)
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.55))
                }
            }
        }
        .padding(.vertical, 3)
    }
}
