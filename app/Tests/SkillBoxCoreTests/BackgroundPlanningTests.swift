import Foundation
import Testing
@testable import SkillBoxApp
@testable import SkillBoxCore

@MainActor
@Suite("Background planning preserves newer decisions")
struct BackgroundPlanningTests {
    @Test("A global refresh does not read the complete library on the UI thread")
    func refreshRunsOutsideUIThread() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let state = PlanningProbeState()
        let model = try fixtureModel(fixture, state: state)
        await model.reload()
        #expect(!state.calls.isEmpty)
        #expect(state.calls.allSatisfy { !$0 })
        #expect(model.syncPlan?.actions.first?.summary == "committed")
    }

    @Test("A late global result or failure cannot replace a newer refresh", arguments: [false, true])
    func lateRefreshIsDiscarded(failOld: Bool) async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let state = PlanningProbeState()
        state.holdNext(failing: failOld)
        let model = try fixtureModel(fixture, state: state)
        let old = Task { await model.reload() }
        await waitForStart(state)
        var targets = await fixture.store.currentSnapshot().targets
        targets[0].displayName = "newer"
        try await fixture.store.replaceTargets(targets)
        await model.reload()
        state.release()
        await old.value
        #expect(model.syncPlan?.actions.first?.summary == "newer")
        #expect(model.errorMessage == nil)
    }

    @Test("Cancelling a pending bulk preview discards its late result and does not save choices")
    func cancelledBulkPreviewCannotReappear() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let state = PlanningProbeState()
        let model = try fixtureModel(fixture, state: state)
        await model.reload()
        let before = await fixture.store.currentSnapshot()
        state.holdNext()
        let preview = Task { await model.prepareUninstallEverywhere(fixture.record) }
        await waitForStart(state)
        model.cancelSyncPreview()
        state.release()
        #expect(await preview.value == false)
        // Wait for the cancelled preview's normal-state refresh to settle.
        await model.reload()
        #expect(model.syncPlan?.actions.first?.summary == "committed")
        #expect(await fixture.store.currentSnapshot().assignments == before.assignments)
        #expect(await fixture.store.currentSnapshot().installations == before.installations)
        #expect(try String(contentsOf: fixture.installed.appendingPathComponent("guide.md"), encoding: .utf8) == "original runtime")
    }

    @Test("Cancelling a refresh never publishes its background result")
    func cancelledRefreshIsDiscarded() async throws {
        let fixture = try await RefreshFixture.make()
        defer { fixture.remove() }
        let state = PlanningProbeState()
        state.holdNext()
        let model = try fixtureModel(fixture, state: state)
        let refresh = Task { await model.reload() }
        await waitForStart(state)
        refresh.cancel()
        state.release()
        await refresh.value
        #expect(model.syncPlan == nil)
        #expect(model.errorMessage == nil)
    }

    private func fixtureModel(_ fixture: RefreshFixture, state: PlanningProbeState) throws -> AppModel {
        try AppModel(libraryRoot: fixture.root.appendingPathComponent("Store"), store: fixture.store, planner: ProbeSyncPlanner(state: state), homeDirectory: fixture.root, startBootstrap: false)
    }

    private func waitForStart(_ state: PlanningProbeState) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !state.hasStarted, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(state.hasStarted)
    }
}

private final class PlanningProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    private var shouldHold = false
    private var shouldFail = false
    private var started = false
    private let gate = DispatchSemaphore(value: 0)
    var calls: [Bool] { lock.withLock { recorded } }
    var hasStarted: Bool { lock.withLock { started } }
    func holdNext(failing: Bool = false) { lock.withLock { shouldHold = true; shouldFail = failing; started = false } }
    func release() { gate.signal() }
    func begin() throws {
        let held = lock.withLock { () -> (Bool, Bool) in
            recorded.append(Thread.isMainThread)
            let result = (shouldHold, shouldFail)
            if shouldHold { shouldHold = false; started = true }
            return result
        }
        // The old implementation must fail without deadlocking the test's UI
        // actor. Only background invocations wait for explicit release.
        if held.0, !Thread.isMainThread {
            guard gate.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
            if held.1 { throw CocoaError(.fileReadUnknown) }
        }
    }
}

private struct ProbeSyncPlanner: SyncPlanner {
    let state: PlanningProbeState
    func makePlan(snapshot: LibrarySnapshot, libraryRoot: URL) throws -> SyncPlan {
        try state.begin()
        let name = snapshot.targets.first?.displayName == "newer" ? "newer" : (snapshot.assignments.contains { !$0.isDesired } ? "draft" : "committed")
        return .init(actions: [.init(kind: .noChange, skillID: snapshot.skills.first?.id ?? UUID(), targetID: snapshot.targets.first?.id ?? UUID(), destinationPath: libraryRoot.path, summary: name)])
    }
}
