import SwiftUI

struct RepositorySidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            List(selection: $model.selectedRepositoryID) {
                ForEach(groupedOwners, id: \.owner) { group in
                    Section(group.owner) {
                        ForEach(group.repositories) { repository in
                            RepositoryRow(repository: repository)
                                .tag(repository.id)
                        }
                    }
                }
            }
            .overlay {
                if model.visibleRepositories.isEmpty {
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
        .searchable(text: $model.searchText, prompt: "Find repositories")
        .navigationTitle("Repositories")
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Organization", selection: $model.selectedOrganization) {
                Text("All organizations").tag("All")
                ForEach(model.organizations, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            Picker("Repository scope", selection: $model.repositoryFilter) {
                ForEach(RepositoryFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(10)
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
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(repository.name).fontWeight(.medium)
                    if repository.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = repository.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
