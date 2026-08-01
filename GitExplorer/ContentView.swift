import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            RepositorySidebar()
                .navigationSplitViewColumnWidth(300)
        } detail: {
            ZStack {
                if let repository = model.selectedRepository {
                    RepositoryDetailView(repository: repository)
                        .id(repository.id)
                } else if !model.isLoading {
                    ContentUnavailableView(
                        "Select a Repository",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Choose a repository from the sidebar to explore it.")
                    )
                }

                if model.isLoading {
                    PaneLoadingView(
                        model.repositories.isEmpty ? "Loading repository…" : "Refreshing repository…"
                    )
                    .background(.regularMaterial)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                ErrorBanner(message: error) { model.errorMessage = nil }
                    .padding()
            }
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

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(2)
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8)
    }
}
