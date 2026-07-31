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

enum GitGraphLayout {
    static func make(commits: [GitCommit]) -> [CommitLayout] {
        var lanes: [String?] = []
        var output: [CommitLayout] = []

        for commit in commits {
            let matching = lanes.indices.filter { lanes[$0] == commit.id }
            let hasIncomingConnection = !matching.isEmpty
            let lane: Int
            if let first = matching.first {
                lane = first
                for duplicate in matching.dropFirst() { lanes[duplicate] = nil }
            } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                lane = empty
                lanes[empty] = commit.id
            } else {
                lane = lanes.count
                lanes.append(commit.id)
            }

            let passThroughLanes = lanes.indices.filter { $0 != lane && lanes[$0] != nil }
            lanes[lane] = nil
            var connections: [CommitConnection] = []

            for (index, parent) in commit.parents.enumerated() {
                let parentLane: Int
                let colorLane: Int
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentLane = existing
                    // Keep the source lane's colour as it joins an already active
                    // line, so the terminating branch visibly merges into it.
                    colorLane = lane
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
                    passThroughLanes: passThroughLanes,
                    hasIncomingConnection: hasIncomingConnection
                )
            )

            while lanes.last == nil { lanes.removeLast() }
        }
        return output
    }
}
