import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case git = "Git"
    case github = "GitHub"
    case artificialIntelligence = "Artificial Intelligence"
    case locations = "Locations"

    var id: Self { self }

    var icon: String {
        switch self {
        case .git: "point.3.connected.trianglepath.dotted"
        case .github: "person.crop.circle"
        case .artificialIntelligence: "sparkles"
        case .locations: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPane: SettingsPane = .git
    @State private var tokenDraft = ""
    @State private var isEditingToken = false
    @State private var apiKeyDraft = ""
    @State private var isEditingAPIKey = false

    var body: some View {
        // NavigationSplitView always reserves title-bar space above the sidebar.
        // A plain HStack + hiddenTitleBar lets the nav column fill under the traffic lights.
        HStack(spacing: 0) {
            settingsNavigation

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(selectedPane.rawValue)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                paneContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private var settingsNavigation: some View {
        VStack(spacing: 4) {
            ForEach(SettingsPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    Label(pane.rawValue, systemImage: pane.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ResponsiveButtonStyle(
                    isSelected: selectedPane == pane,
                    shape: .rounded(8),
                    selectedBackground: .accentColor
                ))
                .foregroundStyle(selectedPane == pane ? .white : .primary)
                .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .padding(.top, 28) // sit below the traffic lights; background still fills to the top
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .git: gitPane
        case .github: githubPane
        case .artificialIntelligence: artificialIntelligencePane
        case .locations: locationsPane
        }
    }

    private var gitPane: some View {
        SettingsPage {
            SettingsGroup("Git installation") {
                switch model.gitAvailability {
                case .checking:
                    SettingsLabeledRow("Status") {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                    .settingsRow()
                case let .available(path, version):
                    SettingsLabeledRow("Status") {
                        Label("Available", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .settingsRow()
                    Divider().padding(.horizontal, 12)
                    SettingsLabeledRow("Version") {
                        Text(version)
                    }
                        .settingsRow()
                    Divider().padding(.horizontal, 12)
                    SettingsLabeledRow("Executable") {
                        Text(path)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .settingsRow()
                case let .missing(message):
                    SettingsLabeledRow("Status") {
                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .settingsRow()
                    Divider().padding(.horizontal, 12)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .settingsRow()
                }
            }
        }
    }

    private var githubPane: some View {
        SettingsPage {
            SettingsGroup("Authentication") {
                if isEditingToken || trimmedToken.isEmpty {
                    HStack(spacing: 8) {
                        SecureField("Personal access token", text: $tokenDraft)
                            .textContentType(.password)

                        Button("Save") {
                            saveToken()
                        }
                        .disabled(trimmedTokenDraft.isEmpty)
                    }
                    .settingsRow()
                } else {
                    HStack(spacing: 12) {
                        Label("Stored in Keychain (\(maskedToken))", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change API Key") {
                            tokenDraft = ""
                            isEditingToken = true
                        }
                    }
                    .settingsRow()
                }

                Divider().padding(.horizontal, 12)

                Text("The token is stored securely in your macOS Keychain. Use a fine-grained token with read access to repository metadata and contents, or a classic token with repo and read:org scopes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsRow()
            }

            SettingsGroup("Connection") {
                SettingsLabeledRow("Status") {
                    githubStatusLabel
                }
                .settingsRow()

                Divider().padding(.horizontal, 12)

                SettingsLabeledRow("Account") {
                    Text(model.githubAccountName.map { "@\($0)" } ?? "—")
                        .foregroundStyle(isCheckingConnection ? .tertiary : .primary)
                }
                .settingsRow()

                if case let .failed(message) = model.githubConnectionStatus {
                    Divider().padding(.horizontal, 12)

                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .settingsRow()
                }

                Divider().padding(.horizontal, 12)

                HStack {
                    Spacer()
                    Button("Test Connection") {
                        Task { await model.testGitHubConnection() }
                    }
                    .disabled(trimmedToken.isEmpty || isCheckingConnection)
                }
                .settingsRow()
            }
        }
    }

    @ViewBuilder
    private var githubStatusLabel: some View {
        switch model.githubConnectionStatus {
        case .notConfigured:
            Label(
                trimmedToken.isEmpty ? "Not configured" : "Ready to connect",
                systemImage: "circle.dashed"
            )
            .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Connection failed", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var locationsPane: some View {
        SettingsPage {
            SettingsGroup("Local repositories") {
                HStack(spacing: 12) {
                    Text(model.reposDirectory?.path(percentEncoded: false) ?? "No folder selected")
                        .foregroundStyle(model.reposDirectory == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Choose…") {
                        Task { await model.chooseReposDirectory() }
                    }
                }
                .settingsRow()
            }
        }
    }

    private var artificialIntelligencePane: some View {
        SettingsPage {
            SettingsGroup("OpenAI") {
                if isEditingAPIKey || trimmedAPIKey.isEmpty {
                    HStack(spacing: 8) {
                        SecureField("OpenAI API key", text: $apiKeyDraft)
                            .textContentType(.password)

                        Button("Save") {
                            saveAPIKey()
                        }
                        .disabled(trimmedAPIKeyDraft.isEmpty)
                    }
                    .settingsRow()
                } else {
                    HStack(spacing: 12) {
                        Label("Stored in Keychain (\(maskedAPIKey))", systemImage: "key.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Change API Key") {
                            apiKeyDraft = ""
                            isEditingAPIKey = true
                        }
                    }
                    .settingsRow()
                }

                Divider().padding(.horizontal, 12)

                Text("The key is stored securely in your macOS Keychain and is never shown again after you save it. Git Explorer uses GPT-5.6 Luna to generate commit messages from the complete staged diff.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsRow()
            }
        }
    }

    private var trimmedToken: String {
        model.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTokenDraft: String {
        tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKey: String {
        model.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var maskedAPIKey: String {
        "…" + String(trimmedAPIKey.suffix(8))
    }

    private var maskedToken: String {
        "…" + String(trimmedToken.suffix(8))
    }

    private var isCheckingConnection: Bool {
        model.githubConnectionStatus == .checking
    }

    private func saveToken() {
        model.githubToken = trimmedTokenDraft
        model.githubCredentialsChanged()
        tokenDraft = ""
        isEditingToken = false
        Task { await model.saveToken() }
    }

    private func saveAPIKey() {
        model.openAIAPIKey = trimmedAPIKeyDraft
        apiKeyDraft = ""
        isEditingAPIKey = false
        model.saveOpenAIAPIKey()
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)

            VStack(spacing: 0) {
                content
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsLabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label)
            Spacer(minLength: 20)
            content
        }
    }
}

private extension View {
    func settingsRow() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppModel())
        .frame(width: 720, height: 480)
}
