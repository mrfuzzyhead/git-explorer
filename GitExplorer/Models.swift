import Foundation

enum SourceControlProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case github
    case azureDevOps

    var id: Self { self }

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .azureDevOps: "Azure DevOps"
        }
    }

    var icon: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .azureDevOps: "cloud"
        }
    }
}

struct SourceControlAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let provider: SourceControlProvider
    var displayName: String
    var organization: String?
}

struct Repository: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var fullName: String
    var owner: String
    var description: String?
    var webURL: URL?
    var cloneURL: URL?
    var defaultBranch: String?
    var isPrivate: Bool
    var localURL: URL?
    var updatedAt: Date?
    var sourceProvider: SourceControlProvider? = nil
    var sourceAccountID: UUID? = nil
    var remoteIdentifier: String? = nil
    var remoteProject: String? = nil

    var isLocal: Bool { localURL != nil }
    var provider: SourceControlProvider? {
        sourceProvider ?? (webURL?.host?.lowercased() == "github.com" ? .github : nil)
    }
}

struct GitCommit: Identifiable, Hashable {
    let id: String
    let parents: [String]
    let author: String
    let timestamp: Date
    let message: String
    let description: String?
    let branches: [String]
    let tags: [String]
    let isHead: Bool
    var children: [String] = []

    var abbreviatedID: String { String(id.prefix(7)) }
}

struct GitCommitPage {
    let commits: [GitCommit]
    let hasMore: Bool
}

struct GitHubWorkflowRun: Identifiable, Hashable {
    let id: Int64
    let workflowTitle: String
    let commitTitle: String
    let commitAuthor: String
    let branch: String
    let status: String
    let conclusion: String?
    let createdAt: Date
    let startedAt: Date?
    let updatedAt: Date
    let webURL: URL

    var isRunning: Bool { status != "completed" }

    var displayStatus: GitHubWorkflowRunDisplayStatus {
        guard status == "completed" else { return .inProgress }
        return conclusion == "success" ? .complete : .failed
    }

    func elapsedTime(at currentDate: Date = .now) -> TimeInterval {
        let startDate = startedAt ?? createdAt
        let endDate = isRunning ? currentDate : updatedAt
        return max(0, endDate.timeIntervalSince(startDate))
    }
}

enum GitHubWorkflowRunDisplayStatus: Equatable {
    case inProgress
    case complete
    case failed
}

struct GitHubWorkflowRunPage {
    let runs: [GitHubWorkflowRun]
    let hasMore: Bool
}

struct CommitConnection: Hashable {
    let fromLane: Int
    let toLane: Int
    let colorLane: Int
}

struct CommitLayout: Identifiable, Hashable {
    var id: String { commit.id }
    let commit: GitCommit
    let lane: Int
    let laneCount: Int
    let connections: [CommitConnection]
    let incomingConnections: [CommitConnection]
    let passThroughLanes: [Int]
    let hasIncomingConnection: Bool
}

struct RepositoryGraphLayout {
    let workingTree: CommitLayout?
    let commits: [CommitLayout]
}

struct RepositoryStatus: Equatable {
    var branch = "Detached HEAD"
    var upstream: String?
    var ahead = 0
    var behind = 0
    var hasChanges = false
    var conflictedFileCount = 0

    var hasMergeConflicts: Bool { conflictedFileCount > 0 }

    func divergence(for reference: String) -> BranchDivergence? {
        if reference == branch {
            return BranchDivergence(ahead: ahead, behind: behind).nonzero
        }
        if reference == upstream {
            return BranchDivergence(ahead: behind, behind: ahead).nonzero
        }
        return nil
    }
}

struct DashboardStatusReport: Equatable {
    var statuses: [Repository.ID: RepositoryStatus] = [:]
    var errors: [Repository.ID: String] = [:]
}

struct BranchDivergence: Equatable {
    let ahead: Int
    let behind: Int

    fileprivate var nonzero: Self? {
        ahead > 0 || behind > 0 ? self : nil
    }
}

enum GitAvailability: Equatable {
    case checking
    case available(path: String, version: String)
    case missing(message: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct CommitDetails {
    let commit: GitCommit
    let changedFiles: [String]
    let fileDiffs: [String: String]

    var diff: String {
        changedFiles.compactMap { fileDiffs[$0] }.joined(separator: "\n\n")
    }
}

struct MergeConflictFile: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let hunks: [MergeConflictHunk]
}

struct MergeConflictHunk: Identifiable, Equatable {
    let id: Int
    let currentLabel: String
    let incomingLabel: String
    let current: String
    let incoming: String
}

enum MergeConflictChoice: String, CaseIterable, Identifiable {
    case current
    case incoming
    case both

    var id: Self { self }
}

struct MergeConflictResolution {
    let filePath: String
    let choices: [Int: MergeConflictChoice]
}

struct WorkingTreeFile: Identifiable, Hashable {
    enum Area: Hashable {
        case staged
        case unstaged
    }

    var id: String { "\(area)-\(path)" }
    let path: String
    let originalPath: String?
    let status: String
    let area: Area
}

struct WorkingTreeState: Equatable {
    let unstaged: [WorkingTreeFile]
    let staged: [WorkingTreeFile]

    static let empty = WorkingTreeState(unstaged: [], staged: [])
}

struct RemoteFileEntry: Identifiable, Hashable {
    enum Kind: String {
        case file, directory
    }

    var id: String { path }
    let name: String
    let path: String
    let kind: Kind
    let size: Int
    let webURL: URL?
}

enum RepositoryFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case local = "local"
    case remoteOnly = "remote"
    var id: Self { self }
}
