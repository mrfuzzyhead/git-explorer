import Foundation

enum CommitHoverSurface: Equatable {
    case graph
    case metadata
}

struct CommitHoverTarget: Equatable {
    let commitID: String
    let surface: CommitHoverSurface
}

enum CommitHoverEvent: Equatable {
    case entered(CommitHoverTarget)
    case exited(CommitHoverTarget)
}

enum CommitHoverState {
    static func reduce(
        current: CommitHoverTarget?,
        event: CommitHoverEvent
    ) -> CommitHoverTarget? {
        switch event {
        case let .entered(target):
            return target
        case let .exited(target):
            return current == target ? nil : current
        }
    }
}

enum CommitGraphFilter {
    static func commitIDs(reachableFrom branch: String, in commits: [GitCommit]) -> Set<String> {
        let commitsByID = Dictionary(uniqueKeysWithValues: commits.map { ($0.id, $0) })
        var reachable = Set(commits.lazy
            .filter { $0.branches.contains(branch) }
            .map(\.id))
        var pending = Array(reachable)

        while let id = pending.popLast(), let commit = commitsByID[id] {
            for parent in commit.parents where reachable.insert(parent).inserted {
                pending.append(parent)
            }
        }

        return reachable
    }
}

struct CommitBranchLabel: Equatable {
    let name: String
    let actionName: String
    let includesRemote: Bool
}

enum CommitReferencePresentation {
    static func branchLabels(for branches: [String]) -> [CommitBranchLabel] {
        let names = Set(branches)
        var seen: Set<String> = []
        var labels: [CommitBranchLabel] = []

        for branch in branches {
            guard branch != "origin/HEAD" else { continue }

            if branch.hasPrefix("origin/") {
                let localName = String(branch.dropFirst("origin/".count))
                if names.contains(localName) { continue }
            }

            guard seen.insert(branch).inserted else { continue }
            let remoteName = "origin/\(branch)"
            labels.append(CommitBranchLabel(
                name: branch,
                actionName: branch,
                includesRemote: names.contains(remoteName)
            ))
        }

        return labels
    }
}

enum CommitAgeFormatter {
    static func string(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        let minute = 60.0
        let hour = minute * 60

        if elapsed < hour {
            return "\(max(1, Int(elapsed / minute))) mins ago"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return "\(Int(elapsed / hour)) hours ago"
        }
        if isYesterday(date, relativeTo: now, calendar: calendar) {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    static func updatedString(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        string(for: date, relativeTo: now, calendar: calendar)
    }

    private static func isYesterday(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let startOfYesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        ) else { return false }

        return date >= startOfYesterday && date < calendar.startOfDay(for: now)
    }
}

enum GitGraphLayout {
    private static let workingTreeID = "git-explorer-working-tree"

    static func makeRepositoryLayout(
        commits: [GitCommit],
        hasUncommittedChanges: Bool,
        hasMergeConflicts: Bool = false
    ) -> RepositoryGraphLayout {
        guard hasUncommittedChanges else {
            return RepositoryGraphLayout(workingTree: nil, commits: make(commits: commits))
        }

        let headID = commits.first(where: \.isHead)?.id
        let workingTree = GitCommit(
            id: workingTreeID,
            parents: headID.map { [$0] } ?? [],
            author: "",
            timestamp: Date(),
            message: hasMergeConflicts ? "Merge conflicts" : "Uncommitted changes",
            description: nil,
            branches: [],
            tags: [],
            isHead: false
        )
        let layouts = make(commits: [workingTree] + commits)
        return RepositoryGraphLayout(
            workingTree: layouts.first,
            commits: Array(layouts.dropFirst())
        )
    }

    static func make(commits: [GitCommit]) -> [CommitLayout] {
        var lanes: [String?] = []
        var output: [CommitLayout] = []

        for commit in commits {
            let matching = lanes.indices.filter { lanes[$0] == commit.id }
            let hasIncomingConnection = !matching.isEmpty
            let lane: Int
            let incomingConnections: [CommitConnection]
            if let first = matching.first {
                lane = first
                incomingConnections = matching.dropFirst().map {
                    CommitConnection(fromLane: $0, toLane: lane, colorLane: $0)
                }
                for duplicate in matching.dropFirst() { lanes[duplicate] = nil }
            } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                lane = empty
                lanes[empty] = commit.id
                incomingConnections = []
            } else {
                lane = lanes.count
                lanes.append(commit.id)
                incomingConnections = []
            }

            let passThroughLanes = lanes.indices.filter { $0 != lane && lanes[$0] != nil }
            lanes[lane] = nil
            var connections: [CommitConnection] = []

            for (index, parent) in commit.parents.enumerated() {
                let parentLane: Int
                let colorLane: Int
                if lanes.contains(where: { $0 == parent }) {
                    // Keep a second reservation for the shared parent so this
                    // branch remains visible until it reaches that parent row.
                    // The duplicate reservations are joined at the parent node.
                    if index == 0 && lanes[lane] == nil {
                        parentLane = lane
                    } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                        parentLane = empty
                    } else {
                        parentLane = lanes.count
                        lanes.append(nil)
                    }
                    lanes[parentLane] = parent
                    colorLane = parentLane
                } else if index == 0 && lanes[lane] == nil {
                    parentLane = lane
                    lanes[lane] = parent
                    colorLane = parentLane
                } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                    parentLane = empty
                    lanes[empty] = parent
                    colorLane = parentLane
                } else {
                    parentLane = lanes.count
                    lanes.append(parent)
                    colorLane = parentLane
                }
                connections.append(
                    .init(fromLane: lane, toLane: parentLane, colorLane: colorLane)
                )
            }

            output.append(
                CommitLayout(
                    commit: commit,
                    lane: lane,
                    laneCount: max(lanes.count, lane + 1),
                    connections: connections,
                    incomingConnections: incomingConnections,
                    passThroughLanes: passThroughLanes,
                    hasIncomingConnection: hasIncomingConnection
                )
            )

            while lanes.last == nil { lanes.removeLast() }
        }
        return output
    }
}
