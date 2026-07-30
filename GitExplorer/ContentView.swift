import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            RepositorySidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
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
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
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
