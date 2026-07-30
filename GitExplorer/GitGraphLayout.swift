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

enum GitGraphLayout {
    static func make(commits: [GitCommit]) -> [CommitLayout] {
        var lanes: [String?] = []
        var output: [CommitLayout] = []

        for commit in commits {
            let matching = lanes.indices.filter { lanes[$0] == commit.id }
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
                if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    parentLane = existing
                } else if index == 0 && lanes[lane] == nil {
                    parentLane = lane
                    lanes[lane] = parent
                } else if let empty = lanes.firstIndex(where: { $0 == nil }) {
                    parentLane = empty
                    lanes[empty] = parent
                } else {
                    parentLane = lanes.count
                    lanes.append(parent)
                }
                connections.append(.init(fromLane: lane, toLane: parentLane))
            }

            output.append(
                CommitLayout(
                    commit: commit,
                    lane: lane,
                    laneCount: max(lanes.count, lane + 1),
                    connections: connections,
                    passThroughLanes: passThroughLanes
                )
            )

            while lanes.last == nil { lanes.removeLast() }
        }
        return output
    }
}
