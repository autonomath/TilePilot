#if canImport(XCTest)
import XCTest
@testable import TilePilot

final class WorkSetModelsTests: XCTestCase {
    private var previousWorkSetsData: Data?
    private var previousActiveWorkSetIDs: [String: String]?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        previousWorkSetsData = defaults.data(forKey: AppModel.workSetsDefaultsKey)
        previousActiveWorkSetIDs = defaults.dictionary(forKey: AppModel.activeWorkSetIDsByScopeDefaultsKey) as? [String: String]
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let previousWorkSetsData {
            defaults.set(previousWorkSetsData, forKey: AppModel.workSetsDefaultsKey)
        } else {
            defaults.removeObject(forKey: AppModel.workSetsDefaultsKey)
        }
        if let previousActiveWorkSetIDs {
            defaults.set(previousActiveWorkSetIDs, forKey: AppModel.activeWorkSetIDsByScopeDefaultsKey)
        } else {
            defaults.removeObject(forKey: AppModel.activeWorkSetIDsByScopeDefaultsKey)
        }
        super.tearDown()
    }

    func testResolveWorkSetMembersPrefersExactMatchBeforeFallback() {
        let exact = makeWindow(id: 101, pid: 9001, app: "Safari", title: "Inbox")
        let otherSameApp = makeWindow(id: 202, pid: 9002, app: "Safari", title: "Other")
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembers([member], in: [otherSameApp, exact])

        XCTAssertEqual(resolved.first?.matchedWindow?.id, 101)
        XCTAssertEqual(resolved.first?.status, .exact)
    }

    func testResolveWorkSetMembersFallsBackToSameAppWhenExactWindowIsGone() {
        let fallback = makeWindow(id: 202, pid: 9002, app: "Safari", title: "Inbox")
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembers([member], in: [fallback])

        XCTAssertEqual(resolved.first?.matchedWindow?.id, 202)
        XCTAssertEqual(resolved.first?.status, .sameApp)
    }

    func testResolveWorkSetMembersLeavesMissingWhenNoSameAppWindowExists() {
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembers([member], in: [makeWindow(id: 303, pid: 1234, app: "Notes", title: "Todo")])

        XCTAssertNil(resolved.first?.matchedWindow)
        XCTAssertEqual(resolved.first?.status, .missing)
    }

    func testResolveWorkSetMembersDoesNotReuseOneLiveWindowTwice() {
        let sharedWindow = makeWindow(id: 101, pid: 9001, app: "Safari", title: "Inbox")
        let members = [
            WorkSetMember(appName: "Safari", windowTitle: "Inbox", role: "AXWindow", subrole: "AXStandardWindow", lastSeenWindowID: 101, lastSeenPID: 9001),
            WorkSetMember(appName: "Safari", windowTitle: "Other", role: "AXWindow", subrole: "AXStandardWindow", lastSeenWindowID: 999, lastSeenPID: 999)
        ]

        let resolved = resolveWorkSetMembers(members, in: [sharedWindow])

        XCTAssertEqual(resolved[0].status, .exact)
        XCTAssertEqual(resolved[0].matchedWindow?.id, 101)
        XCTAssertEqual(resolved[1].status, .missing)
        XCTAssertNil(resolved[1].matchedWindow)
    }

    func testResolveWorkSetMembersForScopeReportsMinimizedWindow() {
        let minimized = makeWindow(id: 101, pid: 9001, app: "Safari", title: "Inbox", isMinimized: true)
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembersForScope(
            [member],
            visibleScopeWindows: [],
            allWindows: [minimized],
            scopeKey: WorkSetScopeKey(displayID: 1, spaceIndex: 1)
        )

        XCTAssertEqual(resolved.first?.status, .minimized)
        XCTAssertEqual(resolved.first?.matchedWindow?.id, 101)
    }

    func testResolveWorkSetMembersForScopeReportsOtherDesktop() {
        let otherDesktop = makeWindow(id: 101, pid: 9001, app: "Safari", title: "Inbox", space: 2)
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembersForScope(
            [member],
            visibleScopeWindows: [],
            allWindows: [otherDesktop],
            scopeKey: WorkSetScopeKey(displayID: 1, spaceIndex: 1)
        )

        XCTAssertEqual(resolved.first?.status, .otherDesktop)
        XCTAssertEqual(resolved.first?.matchedWindow?.id, 101)
    }

    func testResolveWorkSetMembersForScopeReportsOtherScreen() {
        let otherScreen = makeWindow(id: 101, pid: 9001, app: "Safari", title: "Inbox", display: 2)
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )

        let resolved = resolveWorkSetMembersForScope(
            [member],
            visibleScopeWindows: [],
            allWindows: [otherScreen],
            scopeKey: WorkSetScopeKey(displayID: 1, spaceIndex: 1)
        )

        XCTAssertEqual(resolved.first?.status, .otherScreen)
        XCTAssertEqual(resolved.first?.matchedWindow?.id, 101)
    }

    func testNextWorkSetToCycleReturnsFirstWhenNoActiveWorkSetExists() {
        let workSets = [
            makeWorkSet(name: "One"),
            makeWorkSet(name: "Two"),
            makeWorkSet(name: "Three")
        ]

        let next = nextWorkSetToCycle(in: workSets, activeWorkSetID: nil)

        XCTAssertEqual(next?.id, workSets[0].id)
    }

    func testNextWorkSetToCycleReturnsNextAfterActiveWorkSet() {
        let workSets = [
            makeWorkSet(name: "One"),
            makeWorkSet(name: "Two"),
            makeWorkSet(name: "Three")
        ]

        let next = nextWorkSetToCycle(in: workSets, activeWorkSetID: workSets[0].id)

        XCTAssertEqual(next?.id, workSets[1].id)
    }

    func testNextWorkSetToCycleWrapsAroundToFirst() {
        let workSets = [
            makeWorkSet(name: "One"),
            makeWorkSet(name: "Two"),
            makeWorkSet(name: "Three")
        ]

        let next = nextWorkSetToCycle(in: workSets, activeWorkSetID: workSets[2].id)

        XCTAssertEqual(next?.id, workSets[0].id)
    }

    func testWorkSetDecodeBackfillsBackdropFieldsForExistingData() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "name": "Writing",
          "sourceDisplayName": "Studio Display",
          "scopeKey": {
            "displayID": 1,
            "spaceIndex": 2
          },
          "members": []
        }
        """

        let decoded = try JSONDecoder().decode(WorkSet.self, from: Data(json.utf8))

        XCTAssertFalse(decoded.backdropEnabled)
        XCTAssertEqual(decoded.backdropColor, .workSetBackdropDefault)
        XCTAssertFalse(decoded.launchMissingApps)
    }

    func testWorkSetMemberDecodeBackfillsLaunchMetadataForExistingData() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "appName": "Safari",
          "windowTitle": "Inbox",
          "role": "AXWindow",
          "subrole": "AXStandardWindow",
          "lastSeenWindowID": 101,
          "lastSeenPID": 9001
        }
        """

        let decoded = try JSONDecoder().decode(WorkSetMember.self, from: Data(json.utf8))

        XCTAssertNil(decoded.bundleIdentifier)
        XCTAssertNil(decoded.bundleURLPath)
    }

    func testWorkSetMemberPreservesLaunchMetadata() {
        let member = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001,
            bundleIdentifier: "com.apple.Safari",
            bundleURLPath: "/Applications/Safari.app"
        )

        XCTAssertEqual(member.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(member.bundleURLPath, "/Applications/Safari.app")
    }

    @MainActor
    func testOrderedWorkSetCandidateWindowsUsesWindowServerFrontToBackOrder() {
        let model = AppModel()
        let windows = [
            makeWindow(id: 301, pid: 1, app: "Mail", title: "Back", focused: false, windowServerOrderIndex: 2),
            makeWindow(id: 302, pid: 2, app: "Safari", title: "Front", focused: false, windowServerOrderIndex: 0),
            makeWindow(id: 303, pid: 3, app: "Notes", title: "Middle", focused: true, windowServerOrderIndex: 1)
        ]

        let ordered = model.orderedWorkSetCandidateWindows(from: windows)

        XCTAssertEqual(ordered.map(\.id), [302, 303, 301])
    }

    @MainActor
    func testMoveWorkSetMemberAcrossSetsRemovesSourceAndDedupesDestination() {
        let model = AppModel()
        let scope = WorkSetScopeKey(displayID: 1, spaceIndex: 1)
        let movingMember = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )
        let duplicateDestinationMember = WorkSetMember(
            appName: "Safari",
            windowTitle: "Inbox",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 101,
            lastSeenPID: 9001
        )
        let anchorMember = WorkSetMember(
            appName: "Notes",
            windowTitle: "Todo",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            lastSeenWindowID: 202,
            lastSeenPID: 9002
        )
        let source = WorkSet(
            id: UUID(),
            name: "Source",
            sourceDisplayName: "Built-in",
            scopeKey: scope,
            members: [movingMember]
        )
        let destination = WorkSet(
            id: UUID(),
            name: "Destination",
            sourceDisplayName: "Built-in",
            scopeKey: scope,
            members: [anchorMember, duplicateDestinationMember]
        )

        model.workSets = [source, destination]
        model.moveWorkSetMember(
            from: source.id,
            memberID: movingMember.id,
            to: destination.id,
            before: anchorMember.id
        )

        XCTAssertTrue(model.workSet(withID: source.id)?.members.isEmpty == true)
        XCTAssertEqual(model.workSet(withID: destination.id)?.members.map(\.id), [movingMember.id, anchorMember.id])
    }

    private func makeWindow(
        id: Int,
        pid: Int,
        app: String,
        title: String,
        space: Int = 1,
        display: Int = 1,
        focused: Bool = false,
        windowServerOrderIndex: Int? = nil,
        isMinimized: Bool = false
    ) -> WindowState {
        WindowState(
            id: id,
            pid: pid,
            app: app,
            space: space,
            display: display,
            frameX: 0,
            frameY: 0,
            frameW: 100,
            frameH: 100,
            floating: true,
            hasAXReference: true,
            canMove: true,
            canResize: true,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            focused: focused,
            isVisible: true,
            isMinimized: isMinimized,
            isHidden: false,
            hasWindowServerMatch: true,
            windowServerOrderIndex: windowServerOrderIndex,
            source: .yabai,
            lastUpdatedAt: Date()
        )
    }

    private func makeWorkSet(name: String) -> WorkSet {
        WorkSet(
            id: UUID(),
            name: name,
            sourceDisplayName: "Built-in",
            scopeKey: WorkSetScopeKey(displayID: 1, spaceIndex: 1),
            members: []
        )
    }
}
#endif
