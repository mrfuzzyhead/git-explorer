import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenVisible = false

    var body: some View {
        Form {
            Section("GitHub") {
                HStack {
                    if tokenVisible {
                        TextField("Personal access token", text: $model.githubToken)
                    } else {
                        SecureField("Personal access token", text: $model.githubToken)
                    }
                    Button {
                        tokenVisible.toggle()
                    } label: {
                        Image(systemName: tokenVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    Button("Save") { Task { await model.saveToken() } }
                }
                Text("The token is stored in your macOS Keychain. Use a fine-grained token with read access to repository metadata and contents, or classic scopes repo and read:org.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Git") {
                switch model.gitAvailability {
                case .checking:
                    LabeledContent("Status") { ProgressView().controlSize(.small) }
                case let .available(path, version):
                    LabeledContent("Status", value: version)
                    LabeledContent("Executable", value: path)
                case let .missing(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Local repositories") {
                HStack {
                    Text(model.reposDirectory?.path(percentEncoded: false) ?? "No folder selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { Task { await model.chooseReposDirectory() } }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
