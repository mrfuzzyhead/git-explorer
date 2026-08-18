import SwiftUI

enum ResponsiveControlShape {
    case rounded(CGFloat)
    case capsule
    case circle
}

struct ResponsiveButtonStyle: ButtonStyle {
    var isSelected = false
    var shape = ResponsiveControlShape.rounded(7)
    var selectedBackground = Color.clear
    var hoverBackground = Color.primary.opacity(0.08)
    var pressedScale = 0.98

    func makeBody(configuration: Configuration) -> some View {
        ResponsiveButtonBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isSelected: isSelected,
            shape: shape,
            selectedBackground: selectedBackground,
            hoverBackground: hoverBackground,
            pressedScale: pressedScale
        )
    }
}

private struct ResponsiveButtonBody<Label: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    let label: Label
    let isPressed: Bool
    let isSelected: Bool
    let shape: ResponsiveControlShape
    let selectedBackground: Color
    let hoverBackground: Color
    let pressedScale: CGFloat

    var body: some View {
        label
            .background { background }
            .scaleEffect(isEnabled && isPressed ? pressedScale : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var background: some View {
        switch shape {
        case let .rounded(radius):
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(backgroundColor)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selectedHoverOverlay)
            }
        case .capsule:
            ZStack {
                Capsule().fill(backgroundColor)
                Capsule().fill(selectedHoverOverlay)
            }
        case .circle:
            ZStack {
                Circle().fill(backgroundColor)
                Circle().fill(selectedHoverOverlay)
            }
        }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return isSelected ? selectedBackground : .clear }
        if isSelected { return selectedBackground }
        if isPressed { return Color.primary.opacity(0.14) }
        return isHovered ? hoverBackground : .clear
    }

    private var selectedHoverOverlay: Color {
        guard isEnabled, isSelected, isHovered || isPressed else { return .clear }
        return Color.white.opacity(isPressed ? 0.14 : 0.09)
    }
}

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
            if model.isDashboardPresented {
                DashboardView()
            } else if let repository = model.selectedRepository {
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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showDashboard()
                } label: {
                    Label("Dashboard", systemImage: "rectangle.3.group")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(model.isDashboardPresented ? .accentColor : nil)
                .accessibilityAddTraits(model.isDashboardPresented ? .isSelected : [])
                .help("Open Dashboard")
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
