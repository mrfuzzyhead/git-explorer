import XCTest
@testable import GitExplorer

final class GitGraphLayoutTests: XCTestCase {
    func testHoverEnterSelectsCommit() {
        let target = hoverTarget("new", surface: .metadata)
        XCTAssertEqual(
            CommitHoverState.reduce(current: nil, event: .entered(target)),
            target
        )
    }

    func testStaleHoverExitDoesNotClearNewCommit() {
        let old = hoverTarget("old", surface: .metadata)
        let new = hoverTarget("new", surface: .metadata)
        XCTAssertEqual(
            CommitHoverState.reduce(current: new, event: .exited(old)),
            new
        )
    }

    func testExitFromOtherSurfaceDoesNotClearSameCommit() {
        let graph = hoverTarget("same", surface: .graph)
        let metadata = hoverTarget("same", surface: .metadata)
        XCTAssertEqual(
            CommitHoverState.reduce(current: metadata, event: .exited(graph)),
            metadata
        )
    }

    func testCurrentHoverExitClearsCommit() {
        let current = hoverTarget("current", surface: .metadata)
        XCTAssertNil(
            CommitHoverState.reduce(current: current, event: .exited(current))
        )
    }

    func testLinearHistoryKeepsOneLane() {
        let commits = [
            commit("c", parents: ["b"]),
            commit("b", parents: ["a"]),
            commit("a", parents: [])
        ]
        let result = GitGraphLayout.make(commits: commits)
        XCTAssertEqual(result.map(\.lane), [0, 0, 0])
        XCTAssertTrue(result.allSatisfy { $0.laneCount == 1 })
    }

    func testMergeAllocatesAndThenReusesLanesDeterministically() {
        let commits = [
            commit("m", parents: ["a", "f"]),
            commit("f", parents: ["base"]),
            commit("a", parents: ["base"]),
            commit("base", parents: [])
        ]
        let first = GitGraphLayout.make(commits: commits)
        let second = GitGraphLayout.make(commits: commits)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first[0].connections.count, 2)
        XCTAssertEqual(first[0].connections.map(\.toLane), [0, 1])
        XCTAssertEqual(first[1].lane, 1)
        XCTAssertEqual(first[2].lane, 0)
    }

    func testHeadAndMetadataArePreserved() {
        let source = commit("head", parents: [], isHead: true)
        let layout = GitGraphLayout.make(commits: [source])
        XCTAssertEqual(layout.first?.commit, source)
        XCTAssertEqual(layout.first?.lane, 0)
    }

    func testTenThousandCommitLinearHistoryUsesOneLane() {
        var commits: [GitCommit] = []
        commits.reserveCapacity(10_000)
        for index in (0..<10_000).reversed() {
            let identifier = String(index)
            let parents = index == 0 ? [] : [String(index - 1)]
            commits.append(commit(identifier, parents: parents))
        }
        let layout = GitGraphLayout.make(commits: commits)
        XCTAssertEqual(layout.count, 10_000)
        XCTAssertTrue(layout.allSatisfy { $0.lane == 0 && $0.laneCount == 1 })
    }

    private func commit(_ id: String, parents: [String], isHead: Bool = false) -> GitCommit {
        GitCommit(
            id: id,
            parents: parents,
            author: "Test",
            timestamp: Date(timeIntervalSince1970: 0),
            message: id,
            branches: [],
            tags: [],
            isHead: isHead
        )
    }

    private func hoverTarget(
        _ commitID: String,
        surface: CommitHoverSurface
    ) -> CommitHoverTarget {
        CommitHoverTarget(commitID: commitID, surface: surface)
    }
}
