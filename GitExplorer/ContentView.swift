import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var repositoryColumnWidth: CGFloat = 320

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RepositorySidebar()
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    guard columnVisibility != .detailOnly, width >= 260 else { return }
                    repositoryColumnWidth = min(width, 480)
                }
                .navigationSplitViewColumnWidth(
                    min: 260,
                    ideal: repositoryColumnWidth,
                    max: 480
                )
        } detail: {
            if let repository = model.selectedRepository {
                RepositoryDetailView(repository: repository)
                    .id(repository.id)
            } else {
                ContentUnavailableView(
                    "Select a Repository",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Choose a repository from the sidebar to explore it.")
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            ToastStackView(toasts: model.toasts, dismiss: model.dismissToast)
                .padding(16)
        }
        .safeAreaInset(edge: .top) {
            if case let .missing(message) = model.gitAvailability {
                GitMissingBanner(message: message)
            }
        }
    }
}

struct PaneLoadingView: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private struct GitMissingBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Git is required").fontWeight(.semibold)
                Text(message).font(.caption)
            }
            Spacer()
            Link("Install Git", destination: URL(string: "https://git-scm.com/download/mac")!)
            Link("Apple tools", destination: URL(string: "https://developer.apple.com/xcode/resources/")!)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
    }
}
