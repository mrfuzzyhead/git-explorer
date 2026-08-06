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

struct ConflictResolutionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    let onResolved: () -> Void

    @State private var files: [MergeConflictFile] = []
    @State private var selectedFileID: String?
    @State private var choices: [String: MergeConflictChoice] = [:]
    @State private var isLoading = true
    @State private var isApplying = false

    private var selectedFile: MergeConflictFile? {
        files.first { $0.id == selectedFileID }
    }

    private var totalHunkCount: Int { files.reduce(0) { $0 + $1.hunks.count } }
    private var allHunksResolved: Bool { totalHunkCount > 0 && choices.count == totalHunkCount }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Resolve conflicts")
                        .font(.title2.bold())
                    Text("Choose the version to apply for every conflict hunk.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

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
                ProgressView("Loading merge conflicts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if files.isEmpty {
                ContentUnavailableView(
                    "No merge conflicts",
                    systemImage: "checkmark.circle",
                    description: Text("All conflicted files have been resolved.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    conflictFileList
                        .frame(width: 280)

                    Divider()

                    if let selectedFile {
                        conflictHunks(for: selectedFile)
                    } else {
                        ContentUnavailableView(
                            "Select a file",
                            systemImage: "doc.badge.ellipsis",
                            description: Text("Choose a conflicted file to resolve its hunks.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack {
                    Text("\(choices.count) of \(totalHunkCount) hunks resolved")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply resolutions") { applyResolutions() }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!allHunksResolved || isApplying)
                }
                .padding(20)
            }
        }
        .frame(
            minWidth: 820,
            idealWidth: 980,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .task { await loadConflicts() }
    }

    private var conflictFileList: some View {
        List(files, selection: $selectedFileID) { file in
            HStack(spacing: 8) {
                Image(systemName: unresolvedCount(in: file) == 0
                    ? "checkmark.circle.fill"
                    : "exclamationmark.triangle.fill")
                    .foregroundStyle(unresolvedCount(in: file) == 0 ? Color.green : Color.orange)
                Text(file.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(unresolvedCount(in: file))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .tag(file.id)
            .help(file.path)
        }
    }

    private func conflictHunks(for file: MergeConflictFile) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(file.hunks) { hunk in
                    conflictHunk(hunk, in: file)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func conflictHunk(_ hunk: MergeConflictHunk, in file: MergeConflictFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conflict \(hunk.id + 1)")
                    .font(.headline)
                Spacer()
                if choices[choiceKey(file: file, hunk: hunk)] != nil {
                    Label("Resolved", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                conflictVersion(
                    title: "Current — \(hunk.currentLabel)",
                    content: hunk.current,
                    color: .blue
                )
                conflictVersion(
                    title: "Incoming — \(hunk.incomingLabel)",
                    content: hunk.incoming,
                    color: .purple
                )
            }

            HStack(spacing: 8) {
                choiceButton("Use current", choice: .current, file: file, hunk: hunk)
                choiceButton("Use incoming", choice: .incoming, file: file, hunk: hunk)
                choiceButton("Use both", choice: .both, file: file, hunk: hunk)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private func conflictVersion(title: String, content: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                Text(content.isEmpty ? "(empty)" : content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(content.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .frame(minHeight: 80, maxHeight: 180)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(color.opacity(0.28)) }
    }

    private func choiceButton(
        _ title: String,
        choice: MergeConflictChoice,
        file: MergeConflictFile,
        hunk: MergeConflictHunk
    ) -> some View {
        let key = choiceKey(file: file, hunk: hunk)
        return Button(title) { choices[key] = choice }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(choices[key] == choice ? .accentColor : nil)
    }

    private func choiceKey(file: MergeConflictFile, hunk: MergeConflictHunk) -> String {
        "\(file.path)\u{1f}\(hunk.id)"
    }

    private func unresolvedCount(in file: MergeConflictFile) -> Int {
        file.hunks.filter { choices[choiceKey(file: file, hunk: $0)] == nil }.count
    }

    @MainActor
    private func loadConflicts() async {
        guard let url = repository.localURL else {
            isLoading = false
            return
        }
        do {
            files = try await model.git.mergeConflicts(at: url)
            selectedFileID = files.first?.id
        } catch {
            model.showError(error.localizedDescription, title: "Couldn’t load merge conflicts")
        }
        isLoading = false
    }

    private func applyResolutions() {
        guard let url = repository.localURL else { return }
        let resolutions = files.map { file in
            MergeConflictResolution(
                filePath: file.path,
                choices: Dictionary(uniqueKeysWithValues: file.hunks.compactMap { hunk in
                    choices[choiceKey(file: file, hunk: hunk)].map { (hunk.id, $0) }
                })
            )
        }
        Task {
            isApplying = true
            defer { isApplying = false }
            let toastID = model.showToast(
                title: "Applying conflict resolutions…",
                message: repository.name,
                style: .information,
                showsActivity: true,
                isDismissible: false
            )
            do {
                try await model.git.resolveMergeConflicts(resolutions, at: url)
                model.updateToast(
                    toastID,
                    title: "Merge conflicts resolved",
                    message: "Resolved \(totalHunkCount) conflict \(totalHunkCount == 1 ? "hunk" : "hunks").",
                    style: .success,
                    showsActivity: false,
                    isDismissible: true
                )
                onResolved()
                dismiss()
            } catch {
                model.updateToast(
                    toastID,
                    title: "Couldn’t apply conflict resolutions",
                    message: error.localizedDescription,
                    style: .error,
                    showsActivity: false,
                    isDismissible: true
                )
            }
        }
    }
}
