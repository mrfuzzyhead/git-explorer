import XCTest
@testable import GitExplorer

final class GitGraphLayoutTests: XCTestCase {
    func testActionsColumnsFillAvailableWidthAndResizeWithoutChangingTotal() {
        let fitted = ActionsColumnWidths().fitting(totalWidth: 900)
        XCTAssertEqual(fitted.totalWidth, 900, accuracy: 0.001)

        let resized = fitted.resizing(.status, to: fitted.status + 25)
        XCTAssertEqual(resized.status, fitted.status + 25, accuracy: 0.001)
        XCTAssertEqual(resized.commit, fitted.commit - 25, accuracy: 0.001)
        XCTAssertEqual(resized.totalWidth, fitted.totalWidth, accuracy: 0.001)
    }

    func testGraphColumnsFillTheAvailableTableWidth() {
        let widths = CommitGraphColumnWidths(
            branchTag: 140,
            graph: 70,
            message: 180,
            user: 100,
            date: 80
        )

        let filled = widths.filling(minimumTotalWidth: 800)

        XCTAssertEqual(filled.totalWidth, 800)
        XCTAssertEqual(filled.message, 410)
        XCTAssertEqual(filled.branchTag, widths.branchTag)
        XCTAssertEqual(filled.graph, widths.graph)
        XCTAssertEqual(filled.user, widths.user)
        XCTAssertEqual(filled.date, widths.date)
    }

    func testGraphColumnsKeepTheirWidthWhenWiderThanTheTable() {
        let widths = CommitGraphColumnWidths()

        XCTAssertEqual(widths.filling(minimumTotalWidth: 500).totalWidth, widths.totalWidth)
    }

    func testOriginHeadReferenceIsHidden() {
        XCTAssertEqual(
            CommitReferencePresentation.branchLabels(
                for: ["origin/HEAD", "master", "origin/master"]
            ),
            [CommitBranchLabel(name: "master", actionName: "master", includesRemote: true)]
        )
    }

    func testLocalAndOriginBranchCollapseIntoOneLabel() {
        let labels = CommitReferencePresentation.branchLabels(
            for: ["main", "origin/main", "feature"]
        )

        XCTAssertEqual(labels, [
            CommitBranchLabel(name: "main", actionName: "main", includesRemote: true),
            CommitBranchLabel(name: "feature", actionName: "feature", includesRemote: false)
        ])
    }

    func testRemoteOnlyBranchKeepsItsFullName() {
        XCTAssertEqual(
            CommitReferencePresentation.branchLabels(for: ["origin/release"]),
            [CommitBranchLabel(
                name: "origin/release",
                actionName: "origin/release",
                includesRemote: false
            )]
        )
    }

    func testCommitAgeFormattingUsesRelativeTimeYesterdayThenCalendarDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 5, hour: 12)
        ))

        XCTAssertEqual(
            CommitAgeFormatter.string(
                for: now.addingTimeInterval(-5 * 60),
                relativeTo: now,
                calendar: calendar
            ),
            "5 mins ago"
        )
        XCTAssertEqual(
            CommitAgeFormatter.string(
                for: now.addingTimeInterval(-3 * 3_600),
                relativeTo: now,
                calendar: calendar
            ),
            "3 hours ago"
        )
        XCTAssertEqual(
            CommitAgeFormatter.string(
                for: try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now)),
                relativeTo: now,
                calendar: calendar
            ),
            "Yesterday"
        )
        XCTAssertEqual(
            CommitAgeFormatter.string(
                for: try XCTUnwrap(calendar.date(
                    from: DateComponents(year: 2026, month: 8, day: 3)
                )),
                relativeTo: now,
                calendar: calendar
            ),
            "3 Aug 2026"
        )
    }

    func testUpdatedFormattingUsesTheSamePresentation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            CommitAgeFormatter.updatedString(
                for: now.addingTimeInterval(-2 * 3_600),
                relativeTo: now
            ),
            "2 hours ago"
        )
    }

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

    func testBranchFilterIncludesTipAndItsReachableHistory() {
        let commits = [
            commit("main-tip", parents: ["main-parent"], branches: ["main"]),
            commit("feature-tip", parents: ["shared"], branches: ["feature"]),
            commit("main-parent", parents: ["shared"]),
            commit("shared", parents: [])
        ]

        XCTAssertEqual(
            CommitGraphFilter.commitIDs(reachableFrom: "main", in: commits),
            ["main-tip", "main-parent", "shared"]
        )
    }

    func testBranchFilterIncludesBothParentsOfMergeCommit() {
        let commits = [
            commit("merge", parents: ["main", "feature"], branches: ["release"]),
            commit("main", parents: ["base"]),
            commit("feature", parents: ["base"]),
            commit("base", parents: [])
        ]

        XCTAssertEqual(
            CommitGraphFilter.commitIDs(reachableFrom: "release", in: commits),
            ["merge", "main", "feature", "base"]
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

    func testBranchJoiningExistingLaneStaysSeparateUntilParentNode() {
        let commits = [
            commit("main", parents: ["base"]),
            commit("branch", parents: ["base"]),
            commit("base", parents: [])
        ]

        let result = GitGraphLayout.make(commits: commits)

        XCTAssertEqual(result[1].lane, 1)
        XCTAssertEqual(
            result[1].connections,
            [CommitConnection(fromLane: 1, toLane: 1, colorLane: 1)]
        )
        XCTAssertEqual(
            result[2].incomingConnections,
            [CommitConnection(fromLane: 1, toLane: 0, colorLane: 1)]
        )
    }

    func testBranchPassesThroughInterveningRowsBeforeJoiningParent() {
        let commits = [
            commit("main-tip", parents: ["main-middle"]),
            commit("branch-tip", parents: ["base"]),
            commit("main-middle", parents: ["base"]),
            commit("base", parents: [])
        ]

        let result = GitGraphLayout.make(commits: commits)

        let branchLane = result[1].lane
        XCTAssertEqual(result[1].connections.first?.toLane, branchLane)
        XCTAssertTrue(result[2].passThroughLanes.contains(branchLane))
        XCTAssertEqual(
            result[3].incomingConnections,
            [CommitConnection(fromLane: branchLane, toLane: 0, colorLane: branchLane)]
        )
    }

    func testUnconnectedBranchTipDoesNotDrawLinePastItsDot() {
        let commits = [
            commit("tip", parents: ["root"]),
            commit("root", parents: [])
        ]

        let result = GitGraphLayout.make(commits: commits)

        XCTAssertFalse(result[0].hasIncomingConnection)
        XCTAssertTrue(result[1].hasIncomingConnection)
    }

    func testHeadAndMetadataArePreserved() {
        let source = commit("head", parents: [], isHead: true)
        let layout = GitGraphLayout.make(commits: [source])
        XCTAssertEqual(layout.first?.commit, source)
        XCTAssertEqual(layout.first?.lane, 0)
    }

    func testWorkingTreeRowConnectsToHead() throws {
        let commits = [
            commit("other-tip", parents: ["base"], branches: ["other"]),
            commit("head", parents: ["base"], branches: ["main"], isHead: true),
            commit("base", parents: [])
        ]

        let result = GitGraphLayout.makeRepositoryLayout(
            commits: commits,
            hasUncommittedChanges: true
        )
        let workingTree = try XCTUnwrap(result.workingTree)

        XCTAssertEqual(workingTree.connections.map(\.toLane), [0])
        XCTAssertTrue(result.commits[0].passThroughLanes.contains(0))
        XCTAssertTrue(result.commits[1].hasIncomingConnection)
        XCTAssertEqual(result.commits[1].commit.id, "head")
    }

    func testCleanWorkingTreeDoesNotAddRow() {
        let commits = [commit("head", parents: [], isHead: true)]

        let result = GitGraphLayout.makeRepositoryLayout(
            commits: commits,
            hasUncommittedChanges: false
        )

        XCTAssertNil(result.workingTree)
        XCTAssertEqual(result.commits.map(\.commit), commits)
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

    private func commit(
        _ id: String,
        parents: [String],
        branches: [String] = [],
        isHead: Bool = false
    ) -> GitCommit {
        GitCommit(
            id: id,
            parents: parents,
            author: "Test",
            timestamp: Date(timeIntervalSince1970: 0),
            message: id,
            description: nil,
            branches: branches,
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
