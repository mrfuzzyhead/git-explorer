import Foundation

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

    var isLocal: Bool { localURL != nil }
}

struct GitCommit: Identifiable, Hashable {
    let id: String
    let parents: [String]
    let author: String
    let timestamp: Date
    let message: String
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
