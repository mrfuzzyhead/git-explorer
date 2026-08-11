import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case git = "Git"
    case accounts = "Accounts"
    case artificialIntelligence = "Artificial Intelligence"
    case locations = "Locations"

    var id: Self { self }

    var icon: String {
        switch self {
        case .git: "point.3.connected.trianglepath.dotted"
        case .accounts: "person.crop.circle"
        case .artificialIntelligence: "sparkles"
        case .locations: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPane: SettingsPane = .git
    @State private var accountProvider = SourceControlProvider.github
    @State private var accountOrganization = ""
    @State private var accountToken = ""
    @State private var isAddingAccount = false
    @State private var accountError: String?
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
        case .accounts: accountsPane
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

    private var accountsPane: some View {
        SettingsPage {
            SettingsGroup("Connected accounts") {
                if model.accounts.isEmpty {
                    Text("No accounts connected.")
                        .foregroundStyle(.secondary)
                        .settingsRow()
                } else {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().padding(.horizontal, 12) }
                        accountRow(account)
                    }
                }
            }

            SettingsGroup("Add account") {
                SettingsLabeledRow("Provider") {
                    Picker("Provider", selection: $accountProvider) {
                        ForEach(SourceControlProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
                .settingsRow()

                if accountProvider == .azureDevOps {
                    Divider().padding(.horizontal, 12)
                    SettingsLabeledRow("Organization") {
                        TextField("Organization name", text: $accountOrganization)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                    }
                    .settingsRow()
                }

                Divider().padding(.horizontal, 12)
                SettingsLabeledRow("Personal access token") {
                    SecureField(accountProvider == .github ? "GitHub token" : "Azure DevOps token", text: $accountToken)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                }
                .settingsRow()

                if let accountError {
                    Divider().padding(.horizontal, 12)
                    Text(accountError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsRow()
                }

                Divider().padding(.horizontal, 12)
                HStack {
                    Text("Tokens are stored securely in your macOS Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isAddingAccount { ProgressView().controlSize(.small) }
                    Button("Connect") {
                        addAccount()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddAccount || isAddingAccount)
                }
                .settingsRow()
            }
        }
    }

    @ViewBuilder
    private func accountStatusLabel(_ account: SourceControlAccount) -> some View {
        switch model.accountConnectionStatuses[account.id] ?? .notConfigured {
        case .notConfigured:
            Label("Not configured", systemImage: "circle.dashed")
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

    private func accountRow(_ account: SourceControlAccount) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: account.provider.icon)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName).fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text(account.provider.displayName)
                        if let organization = account.organization { Text("• \(organization)") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                accountStatusLabel(account)
                Button("Test") { Task { await model.testConnection(for: account.id) } }
                Button(role: .destructive) {
                    Task { await model.removeAccount(account) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove account")
            }
            if case let .failed(message) = model.accountConnectionStatuses[account.id] {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .settingsRow()
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

    private var trimmedAPIKey: String {
        model.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAPIKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var maskedAPIKey: String {
        "…" + String(trimmedAPIKey.suffix(8))
    }

    private var canAddAccount: Bool {
        !accountToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (accountProvider == .github || !accountOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func addAccount() {
        guard canAddAccount else { return }
        isAddingAccount = true
        accountError = nil
        Task {
            do {
                try await model.addAccount(
                    provider: accountProvider,
                    organization: accountProvider == .azureDevOps ? accountOrganization : nil,
                    token: accountToken
                )
                accountToken = ""
                accountOrganization = ""
            } catch {
                accountError = error.localizedDescription
            }
            isAddingAccount = false
        }
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
