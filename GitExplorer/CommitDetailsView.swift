import SwiftUI

struct CommitDetailsPanel: View {
    @EnvironmentObject private var model: AppModel
    let repository: Repository
    let commit: GitCommit
    let isWorkingTree: Bool
    var hasMergeConflicts = false
    let onClose: () -> Void
    var onCommit: () -> Void = {}
    @State private var details: CommitDetails?
    @State private var loadError: String?
    @State private var selectedFile: String?
    @State private var createCommitPresented = false
    @State private var resolveConflictsPresented = false
    @AppStorage("commitDetails.messagePanelHeight") private var messagePanelHeight = 180.0
    @AppStorage("commitDetails.diffPanelHeight") private var diffPanelHeight = 360.0
    @State private var messagePanelDragOffset: CGFloat = 0
    @State private var diffPanelDragOffset: CGFloat = 0

    private let minimumMessagePanelHeight: CGFloat = 84
    private let minimumChangedFilesHeight: CGFloat = 120
    private let minimumDiffHeight: CGFloat = 180

    var body: some View {
        GeometryReader { panelGeometry in
            let resolvedMessagePanelHeight = clampedMessagePanelHeight(
                CGFloat(messagePanelHeight) + messagePanelDragOffset,
                containerHeight: panelGeometry.size.height
            )

            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.message)
                                .font(.title2.bold())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let description = commit.description {
                                Text(description)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }

                            if !isWorkingTree {
                                HStack(spacing: 6) {
                                    Label(commit.author, systemImage: "person.circle.fill")
                                    Text("•")
                                        .accessibilityHidden(true)
                                    Text(CommitAgeFormatter.string(for: commit.timestamp))
                                }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 20)
                        .padding(.trailing, isWorkingTree ? 210 : 64)
                        .padding(.vertical, 20)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    HStack(spacing: 12) {
                        if isWorkingTree {
                            Button(hasMergeConflicts ? "Resolve conflicts" : "Create commit") {
                                if hasMergeConflicts {
                                    resolveConflictsPresented = true
                                } else {
                                    createCommitPresented = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        }

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(ResponsiveButtonStyle(shape: .circle))
                        .foregroundStyle(.secondary)
                        .help("Close commit details")
                        .accessibilityLabel("Close commit details")
                    }
                    .padding(20)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 0,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .frame(height: resolvedMessagePanelHeight)

                Divider()

                if let details {
                    GeometryReader { geometry in
                        let resolvedDiffHeight = clampedDiffPanelHeight(
                            CGFloat(diffPanelHeight) - diffPanelDragOffset,
                            containerHeight: geometry.size.height
                        )

                        VStack(spacing: 0) {
                            changedFilesSection(
                                details.changedFiles,
                                selection: $selectedFile,
                                onResizeChanged: { translation in
                                    messagePanelDragOffset = translation
                                },
                                onResizeEnded: { translation in
                                    finishMessagePanelResize(
                                        translation: translation,
                                        containerHeight: panelGeometry.size.height
                                    )
                                }
                            )
                            .frame(height: max(0, geometry.size.height - resolvedDiffHeight))

                            CommitDiffView(
                                diff: selectedFile.flatMap { details.fileDiffs[$0] } ?? "",
                                emptyTitle: selectedFile == nil ? "Select a file" : "No diff available",
                                onResizeChanged: { translation in
                                    diffPanelDragOffset = translation
                                },
                                onResizeEnded: { translation in
                                    finishDiffPanelResize(
                                        translation: translation,
                                        containerHeight: geometry.size.height
                                    )
                                }
                            )
                            .frame(
                                minWidth: 0,
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                            .frame(height: resolvedDiffHeight, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    CommitDetailsFeedback(
                        title: "Couldn’t load commit",
                        systemImage: "exclamationmark.triangle",
                        description: loadError
                    )
                } else {
                    CommitDetailsFeedback(title: "Loading changed files…", isLoading: true)
                }
            }
        }
        .background(.background)
        .sheet(isPresented: $createCommitPresented) {
            CommitCreationView(repository: repository, onCommitted: onCommit)
                .environmentObject(model)
        }
        .sheet(isPresented: $resolveConflictsPresented) {
            ConflictResolutionView(repository: repository, onResolved: onCommit)
                .environmentObject(model)
        }
        .task(id: "\(commit.id)-\(isWorkingTree)") {
            details = nil
            loadError = nil
            selectedFile = nil
            do {
                let loadedDetails: CommitDetails
                if let url = repository.localURL {
                    loadedDetails = if isWorkingTree {
                        try await model.git.workingTreeDetails(for: commit, at: url)
                    } else {
                        try await model.git.details(for: commit, at: url)
                    }
                } else {
                    loadedDetails = try await model.remoteCommitDetails(for: repository, commit: commit)
                }
                details = loadedDetails
                selectedFile = loadedDetails.changedFiles.first
            }
            catch is CancellationError { return }
            catch { loadError = error.localizedDescription }
        }
    }

    private func clampedMessagePanelHeight(
        _ proposedHeight: CGFloat,
        containerHeight: CGFloat
    ) -> CGFloat {
        let maximumHeight = max(
            0,
            containerHeight - minimumChangedFilesHeight - minimumDiffHeight
        )
        let effectiveMinimumHeight = min(minimumMessagePanelHeight, maximumHeight)
        return min(max(proposedHeight, effectiveMinimumHeight), maximumHeight)
    }

    private func finishMessagePanelResize(translation: CGFloat, containerHeight: CGFloat) {
        let resolvedHeight = clampedMessagePanelHeight(
            CGFloat(messagePanelHeight) + translation,
            containerHeight: containerHeight
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            messagePanelHeight = Double(resolvedHeight)
            messagePanelDragOffset = 0
        }
    }

    private func clampedDiffPanelHeight(_ proposedHeight: CGFloat, containerHeight: CGFloat) -> CGFloat {
        let availableHeight = max(0, containerHeight)
        let effectiveMinimumDiffHeight = min(minimumDiffHeight, availableHeight)
        let effectiveMinimumChangedFilesHeight = min(
            minimumChangedFilesHeight,
            max(0, availableHeight - effectiveMinimumDiffHeight)
        )
        let maximumDiffHeight = max(
            effectiveMinimumDiffHeight,
            availableHeight - effectiveMinimumChangedFilesHeight
        )
        return min(max(proposedHeight, effectiveMinimumDiffHeight), maximumDiffHeight)
    }

    private func finishDiffPanelResize(translation: CGFloat, containerHeight: CGFloat) {
        let resolvedHeight = clampedDiffPanelHeight(
            CGFloat(diffPanelHeight) - translation,
            containerHeight: containerHeight
        )
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            diffPanelHeight = Double(resolvedHeight)
            diffPanelDragOffset = 0
        }
    }

    private func fileCountSubtitle(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files") changed"
    }

    private func changedFilesSection(
        _ files: [String],
        selection: Binding<String?>,
        onResizeChanged: @escaping (CGFloat) -> Void,
        onResizeEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fileCountSubtitle(files.count))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(VerticalSplitResizeModifier(
                    helpText: "Drag to resize the commit details and changed files views",
                    onChanged: onResizeChanged,
                    onEnded: onResizeEnded
                ))

            Divider()

            if files.isEmpty {
                CommitDetailsFeedback(
                    title: "No files changed",
                    systemImage: "doc",
                    description: "This commit does not contain file changes."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.offset) { _, file in
                            Button {
                                selection.wrappedValue = file
                            } label: {
                                ChangedFileRow(
                                    change: ChangedFileChange(rawValue: file),
                                    isSelected: selection.wrappedValue == file
                                )
                            }
                            .buttonStyle(ResponsiveButtonStyle(
                                isSelected: selection.wrappedValue == file,
                                shape: .rounded(0),
                                selectedBackground: Color.accentColor.opacity(0.14)
                            ))
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CommitDetailsFeedback: View {
    let title: String
    var systemImage: String? = nil
    var description: String? = nil
    var isLoading = false

    var body: some View {
        VStack(spacing: 8) {
            if isLoading {
                ProgressView()
                    .controlSize(.regular)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))

            if let description {
                Text(description)
                    .font(.callout)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct ChangedFileChange {
    let status: String
    let path: String

    init(rawValue: String) {
        let parts = rawValue.split(separator: "\t", omittingEmptySubsequences: false)
        if parts.count >= 2 {
            status = String(parts[0])
            path = String(parts[parts.count - 1])
        } else {
            status = "changed"
            path = rawValue
        }
    }

    var presentation: (label: String, icon: String, color: Color) {
        switch status.lowercased().first {
        case "a": ("Added", "plus.circle.fill", .green)
        case "d": ("Deleted", "minus.circle.fill", .red)
        case "r": ("Renamed", "arrow.right.circle.fill", .blue)
        case "c": ("Copied", "doc.on.doc.fill", .blue)
        case "u": ("Conflict", "exclamationmark.triangle.fill", .orange)
        default: ("Modified", "pencil.circle.fill", .orange)
        }
    }
}

private struct ChangedFileRow: View {
    let change: ChangedFileChange
    let isSelected: Bool

    var body: some View {
        let presentation = change.presentation
        HStack(spacing: 8) {
            Image(systemName: presentation.icon)
                .font(.subheadline)
                .foregroundStyle(presentation.color)
                .frame(width: 14)

            Text(change.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.label): \(change.path)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
