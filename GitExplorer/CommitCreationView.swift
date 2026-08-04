import SwiftUI

struct CommitCreationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    let onCommitted: () -> Void

    @State private var workingTree = WorkingTreeState.empty
    @State private var unstagedSelection: Set<WorkingTreeFile.ID> = []
    @State private var stagedSelection: Set<WorkingTreeFile.ID> = []
    @State private var message = ""
    @State private var isLoading = true
    @State private var isMutating = false
    @State private var isGenerating = false
    @State private var pushAfterCommit = false
    @State private var pushDestination: String?

    private let messageGenerator = CommitMessageGenerator()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create commit")
                    .font(.title2.bold())

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(ResponsiveButtonStyle(shape: .circle))
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            if isLoading {
                ProgressView("Loading working tree…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    fileColumn(
                        title: "Unstaged files",
                        files: workingTree.unstaged,
                        selection: $unstagedSelection,
                        allowsIgnoring: true
                    )

                    VStack(spacing: 10) {
                        Button {
                            moveToStaged()
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 24, height: 24)
                        }
                        .disabled(unstagedSelection.isEmpty || isMutating)
                        .help("Stage selected files")
                        .accessibilityLabel("Stage selected files")

                        Button {
                            moveToUnstaged()
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 24, height: 24)
                        }
                        .disabled(stagedSelection.isEmpty || isMutating)
                        .help("Unstage selected files")
                        .accessibilityLabel("Unstage selected files")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    fileColumn(
                        title: "Staged files",
                        files: workingTree.staged,
                        selection: $stagedSelection,
                        allowsIgnoring: false
                    )
                }
                .padding(20)
                .frame(maxHeight: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Commit message")
                        .font(.subheadline.weight(.semibold))

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $message)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 11)
                            .accessibilityLabel("Commit message")

                        if message.isEmpty {
                            Text("Describe the changes")
                                .foregroundStyle(.tertiary)
                                .padding(8)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 76)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor))
                    }

                    HStack(spacing: 12) {
                        Button {
                            generateMessage()
                        } label: {
                            if isGenerating {
                                HStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Generating…")
                                }
                            } else {
                                Label("Generate with AI", systemImage: "sparkles")
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(
                            workingTree.staged.isEmpty ||
                            model.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            isGenerating || isMutating
                        )

                        Spacer()

                        Toggle("Push to \(pushDestination ?? "origin")", isOn: $pushAfterCommit)
                            .toggleStyle(.checkbox)
                            .disabled(pushDestination == nil)

                        Button("Commit") {
                            createCommit()
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                        .disabled(
                            workingTree.staged.isEmpty ||
                            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            isMutating || isGenerating
                        )
                    }
                }
                .padding(20)
            }
        }
        .frame(
            minWidth: 820,
            idealWidth: 920,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 650,
            maxHeight: .infinity
        )
        .task { await reload() }
    }

    private func fileColumn(
        title: String,
        files: [WorkingTreeFile],
        selection: Binding<Set<WorkingTreeFile.ID>>,
        allowsIgnoring: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            fileList(
                title: title,
                files: files,
                selection: selection,
                allowsIgnoring: allowsIgnoring
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fileList(
        title: String,
        files: [WorkingTreeFile],
        selection: Binding<Set<WorkingTreeFile.ID>>,
        allowsIgnoring: Bool
    ) -> some View {
        if allowsIgnoring {
            baseFileList(title: title, files: files, selection: selection)
                .contextMenu(forSelectionType: WorkingTreeFile.ID.self) { selectedIDs in
                    ignoreMenu(for: selectedIDs, files: files)
                }
        } else {
            baseFileList(title: title, files: files, selection: selection)
        }
    }

    private func baseFileList(
        title: String,
        files: [WorkingTreeFile],
        selection: Binding<Set<WorkingTreeFile.ID>>
    ) -> some View {
        List(files, selection: selection) { file in
            CommitFileRow(file: file)
                .tag(file.id)
        }
        .overlay {
            if files.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.body)
                    Text(title.hasPrefix("Unstaged") ? "No unstaged files" : "No staged files")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func ignoreMenu(
        for selectedIDs: Set<WorkingTreeFile.ID>,
        files: [WorkingTreeFile]
    ) -> some View {
        let paths = files.filter { selectedIDs.contains($0.id) }.map(\.path)
        if paths.count == 1, let path = paths.first {
            ForEach(Self.ignorePatterns(for: path), id: \.self) { pattern in
                Button("Ignore \"\(pattern)\"") {
                    ignore([pattern])
                }
            }
        } else if !paths.isEmpty {
            Button("Ignore selected files") {
                ignore(paths)
            }
        }
    }

    private func moveToStaged() {
        let files = workingTree.unstaged.filter { unstagedSelection.contains($0.id) }
        mutate {
            try await model.git.stage(files, at: repository.localURL!)
        }
    }

    private func moveToUnstaged() {
        let files = workingTree.staged.filter { stagedSelection.contains($0.id) }
        mutate {
            try await model.git.unstage(files, at: repository.localURL!)
        }
    }

    private func ignore(_ patterns: [String]) {
        mutate {
            try await model.git.addIgnorePatterns(patterns, at: repository.localURL!)
        }
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        guard repository.localURL != nil else { return }
        Task {
            isMutating = true
            defer { isMutating = false }
            do {
                try await operation()
                await reload()
            } catch {
                model.showError(error.localizedDescription, title: "Couldn’t update working tree")
            }
        }
    }

    private func generateMessage() {
        guard let url = repository.localURL else { return }
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                let diff = try await model.git.stagedDiff(at: url)
                message = try await messageGenerator.generate(
                    from: diff,
                    apiKey: model.openAIAPIKey
                )
            } catch {
                model.showError(error.localizedDescription, title: "Couldn’t generate commit message")
            }
        }
    }

    private func createCommit() {
        guard let url = repository.localURL else { return }
        let commitMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            isMutating = true
            defer { isMutating = false }
            let toastID = model.showToast(
                title: "Creating commit…",
                message: repository.name,
                style: .information,
                showsActivity: true,
                isDismissible: false
            )
            do {
                try await model.git.commit(message: commitMessage, at: url)
                if pushAfterCommit {
                    do {
                        try await model.git.push(at: url)
                    } catch {
                        model.updateToast(
                            toastID,
                            title: "Commit created, push failed",
                            message: error.localizedDescription,
                            style: .error,
                            showsActivity: false,
                            isDismissible: true
                        )
                        onCommitted()
                        dismiss()
                        return
                    }
                }
                model.updateToast(
                    toastID,
                    title: pushAfterCommit ? "Commit created and pushed" : "Commit created",
                    message: commitMessage.components(separatedBy: .newlines).first,
                    style: .success,
                    showsActivity: false,
                    isDismissible: true
                )
                onCommitted()
                dismiss()
            } catch {
                model.updateToast(
                    toastID,
                    title: "Commit failed",
                    message: error.localizedDescription,
                    style: .error,
                    showsActivity: false,
                    isDismissible: true
                )
            }
        }
    }

    @MainActor
    private func reload() async {
        guard let url = repository.localURL else {
            isLoading = false
            return
        }
        do {
            workingTree = try await model.git.workingTreeState(at: url)
            pushDestination = await model.git.pushDestination(at: url)
            if pushDestination == nil { pushAfterCommit = false }
            unstagedSelection.formIntersection(workingTree.unstaged.map(\.id))
            stagedSelection.formIntersection(workingTree.staged.map(\.id))
        } catch {
            model.showError(error.localizedDescription, title: "Couldn’t load working tree")
        }
        isLoading = false
    }

    static func ignorePatterns(for path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return [] }
        var patterns = [path]
        if components.count > 1 {
            for count in stride(from: components.count - 1, through: 1, by: -1) {
                patterns.append(components.prefix(count).joined(separator: "/") + "/*")
            }
        }
        return Array(patterns.prefix(7))
    }
}

private struct CommitFileRow: View {
    let file: WorkingTreeFile

    var body: some View {
        HStack(spacing: 8) {
            Text(file.status)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(statusColor)
                .frame(width: 14)

            Text(file.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(file.path)
    }

    private var statusColor: Color {
        switch file.status {
        case "A": .green
        case "D": .red
        case "R", "C": .blue
        default: .orange
        }
    }
}
