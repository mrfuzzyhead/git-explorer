import SwiftUI

struct RepositorySidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var collapsedOwners: Set<String> = []
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            repositoryTools
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(groupedOwners, id: \.owner) { group in
                            OwnerGroup(
                                owner: group.owner,
                                repositories: group.repositories,
                                isExpanded: ownerExpansionBinding(for: group.owner)
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }

                if model.isLoading && model.repositories.isEmpty {
                    PaneLoadingView(
                        model.repositories.isEmpty ? "Loading repositories…" : "Refreshing repositories…"
                    )
                    .background(.regularMaterial)
                } else if isAwaitingSearchQuery {
                    EmptyView()
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
            repositoryScopePicker
                .frame(maxWidth: .infinity)

            refreshButton
        }
        .padding(10)
    }

    private var repositoryScopePicker: some View {
        HStack(spacing: 2) {
            ForEach(RepositoryFilter.allCases) { filter in
                Button {
                    model.repositoryFilter = filter
                    model.searchText = ""
                    isSearchPresented = false
                } label: {
                    Image(systemName: icon(for: filter))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if !isSearchPresented && model.repositoryFilter == filter {
                        Capsule()
                            .fill(Color.accentColor)
                    }
                }
                .foregroundStyle(
                    !isSearchPresented && model.repositoryFilter == filter ? .white : .primary
                )
                .accessibilityAddTraits(
                    !isSearchPresented && model.repositoryFilter == filter ? .isSelected : []
                )
                .accessibilityLabel(filter.rawValue.capitalized)
                .help("\(filter.rawValue.capitalized) repositories")
            }

            Button {
                isSearchPresented.toggle()
                model.searchText = ""
                if isSearchPresented {
                    model.repositoryFilter = .all
                    DispatchQueue.main.async { isSearchFocused = true }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background {
                if isSearchPresented {
                    Capsule()
                        .fill(Color.accentColor)
                }
            }
            .foregroundStyle(isSearchPresented ? .white : .primary)
            .accessibilityAddTraits(isSearchPresented ? .isSelected : [])
            .accessibilityLabel("Search repositories")
            .help("Search repositories")
        }
        .padding(2)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Repository controls")
    }

    private var repositoryTools: some View {
        Group {
            if isSearchPresented {
                TextField("Search repositories", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .background(.quaternary, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(
                                isSearchFocused ? Color.accentColor : Color.secondary.opacity(0.18),
                                lineWidth: isSearchFocused ? 2 : 1
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isSearchPresented)
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .frame(width: 32, height: 32)
        .background(.quaternary, in: Circle())
        .contentShape(Circle())
        .disabled(model.isLoading)
        .help("Refresh repositories")
        .accessibilityLabel("Refresh repositories")
    }

    private func icon(for filter: RepositoryFilter) -> String {
        switch filter {
        case .all: "square.stack.3d.up.fill"
        case .local: "externaldrive.fill"
        case .remoteOnly: "cloud.fill"
        }
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
        let repositories = isAwaitingSearchQuery
            ? []
            : model.visibleRepositories

        return Dictionary(grouping: repositories, by: \.owner)
            .map { ($0.key, $0.value) }
            .sorted { $0.owner.localizedStandardCompare($1.owner) == .orderedAscending }
    }

    private var isAwaitingSearchQuery: Bool {
        isSearchPresented && model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct OwnerGroup: View {
    @EnvironmentObject private var model: AppModel

    let owner: String
    let repositories: [Repository]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Text(owner)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(owner)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Collapse or expand this organization")

            if isExpanded {
                ForEach(repositories) { repository in
                    Button {
                        model.selectedRepositoryID = repository.id
                    } label: {
                        RepositoryRow(
                            repository: repository,
                            isSelected: model.selectedRepositoryID == repository.id
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(
                        model.selectedRepositoryID == repository.id ? .isSelected : []
                    )
                }
            }
        }
    }
}

private struct RepositoryRow: View {
    let repository: Repository
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: repository.isLocal ? "externaldrive.fill" : "cloud.fill")
                .foregroundStyle(repository.isLocal ? .green : .secondary)
                .frame(width: 18)
            HStack {
                Text(repository.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if repository.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.gray.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}
