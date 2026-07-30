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

struct CommitConnection: Hashable {
    let fromLane: Int
    let toLane: Int
}

struct CommitLayout: Identifiable, Hashable {
    var id: String { commit.id }
    let commit: GitCommit
    let lane: Int
    let laneCount: Int
    let connections: [CommitConnection]
    let passThroughLanes: [Int]
}

struct RepositoryStatus: Equatable {
    var branch = "Detached HEAD"
    var ahead = 0
    var behind = 0
    var hasChanges = false
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
    let diff: String
}

enum RepositoryFilter: String, CaseIterable, Identifiable {
    case all = "All repositories"
    case local = "Local"
    case remoteOnly = "Remote only"
    var id: Self { self }
}
