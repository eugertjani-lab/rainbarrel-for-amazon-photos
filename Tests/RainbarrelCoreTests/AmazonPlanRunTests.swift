import Foundation
import Testing
@testable import RainbarrelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func drive(_ method: String, _ path: String) -> String { "\(method) /drive/v1/\(path)" }

// MARK: Apply

@Suite("Applying a plan")
struct PlanApplyTests {
    @Test func trashesEveryEmptyFileAfterReadingItsNodeFirst() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let refreshed = Tally()
        let result = try await fx.apply(plan.id, refresh: { refreshed.next() })

        #expect(refreshed.count == 1)
        #expect(result.kind == .apply && result.planId == plan.id)
        #expect(result.succeeded == 4 && result.skipped == 0 && result.failed == 0 && result.remaining == 0)
        #expect(result.status == .applied && result.stopReason == nil)
        #expect(result.message == "Applied 4 steps.")
        for id in ["E-1", "E-2", "E-3", "E-4"] { #expect(fx.amazon.node(id)?.status == "TRASH") }
        #expect(fx.amazon.node("G-1")?.status == "AVAILABLE")

        // The node is read, then written, one step after the other, in plan order.
        #expect(fx.amazon.calls == [
            drive("GET", "nodes/E-3"), drive("PUT", "trash/E-3"), drive("GET", "nodes/E-4"), drive("PUT", "trash/E-4"),
            drive("GET", "nodes/E-1"), drive("PUT", "trash/E-1"), drive("GET", "nodes/E-2"), drive("PUT", "trash/E-2"),
        ])

        let applied = try fx.reload(plan)
        #expect(applied.status == .applied && applied.appliedAt != nil)
        #expect(applied.summary.states.done == 4 && applied.summary.reversible == 4 && applied.summary.remainingToApply == 0)
        let step = try fx.step(plan, "E-1")
        #expect(step.state == .done && step.result == "Moved to Amazon's trash.")
        #expect(step.after == PlanSnapshot(parent: "F-PHONE", name: "broken1.jpg", status: "TRASH"))
        #expect(step.updatedAt != nil)
    }

    @Test func theLocalCatalogFollowsEachDoneStep() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        #expect(try fx.catalogItemIDs() == ["E-1", "E-2", "E-3", "E-4", "G-1"])
        _ = try await fx.apply(plan.id)
        #expect(try fx.catalogItemIDs() == ["G-1"])
        // What undo needs is kept in the step row.
        #expect(try fx.step(plan, "E-2").catalogItem == PlanFixture.items()[1])
    }

    @Test func aRunMakesNoCallBeforeTheCatalogRefreshHasFinished() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let callsDuringRefresh = Tally()
        let lockFreeDuringRefresh = Switch()
        let result = try await fx.apply(plan.id, refresh: {
            if !fx.amazon.calls.isEmpty { callsDuringRefresh.next() }
            // The real refresh takes the download lock itself, so it must run before the apply run holds it.
            if let probe = try RunLock(path: fx.paths.downloadLockURL.path) {
                lockFreeDuringRefresh.isOn = true
                probe.release()
            }
        })
        #expect(callsDuringRefresh.count == 0)
        #expect(lockFreeDuringRefresh.isOn)
        #expect(result.status == .applied)
    }

    @Test func aFailedRefreshStopsBeforeAnythingIsSentOrChanged() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        await #expect(throws: ToolError.self) {
            _ = try await fx.apply(plan.id, refresh: { throw ToolError("the catalog cannot be read") })
        }
        #expect(fx.amazon.calls.isEmpty)
        #expect(try fx.reload(plan).status == .draft)
    }

    @Test func aNodeThatChangedMeanwhileIsSkippedAndTheRunGoesOn() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.modify("E-1") { $0.name = "renamed.jpg" }
        fx.amazon.modify("E-2") { $0.parents = ["F-DOCS"] }
        fx.amazon.modify("E-3") { $0.md5 = String(repeating: "f", count: 32); $0.size = 5 }
        fx.amazon.modify("E-4") { $0.status = "TRASH" }

        let result = try await fx.apply(plan.id)
        #expect(result.succeeded == 0 && result.skipped == 4 && result.failed == 0 && result.remaining == 0)
        #expect(result.status == .applied)
        #expect(result.message.hasPrefix("Applied 0 steps and skipped 4 steps because the item changed in Amazon"))
        #expect(fx.writeCalls.isEmpty)  // nothing was written

        let reasons = [("E-1", "renamed from \"broken1.jpg\" to \"renamed.jpg\""), ("E-2", "another folder"),
                           ("E-3", "its content changed"), ("E-4", "its status is now TRASH")]
        for (id, text) in reasons {
            let step = try fx.step(plan, id)
            #expect(step.state == .skippedChanged)
            #expect(step.result?.hasPrefix("Changed meanwhile: ") == true && step.result?.contains(text) == true)
        }
        // A skipped file is still in the catalog: nothing happened to it.
        #expect(try fx.catalogItemIDs() == ["E-1", "E-2", "E-3", "E-4", "G-1"])
    }

    @Test func aNodeThatIsGoneIsSkippedAsNoLongerInAmazon() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.remove("E-1")
        let result = try await fx.apply(plan.id)
        #expect(result.succeeded == 3 && result.skipped == 1 && result.status == .applied)
        let step = try fx.step(plan, "E-1")
        #expect(step.state == .skippedChanged && step.result == "No longer in Amazon.")
        #expect(fx.amazon.node("E-2")?.status == "TRASH")
    }

    @Test func aNodeThatCannotBeConfirmedByItsContentIsSkipped() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.modify("E-1") { $0.md5 = nil }
        _ = try await fx.apply(plan.id)
        #expect(try fx.step(plan, "E-1").result?.contains("could not be confirmed") == true)
        #expect(fx.amazon.node("E-1")?.status == "AVAILABLE")
    }

    @Test func throttlingIsWaitedOutAndTheSameStepIsTriedAgain() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let attempts = Tally()
        fx.amazon.override { request in
            if request.method == "PUT", request.url.path == "/drive/v1/trash/E-1", attempts.next() <= 2 {
                return .body(Data(), status: 429, headers: ["Retry-After": "7"])
            }
            return nil
        }
        let result = try await fx.apply(plan.id)
        #expect(result.status == .applied && result.succeeded == 4 && result.failed == 0)
        // Every try starts with a fresh read, so the node is compared again before it is written.
        #expect(fx.amazon.calls.filter { $0 == drive("GET", "nodes/E-1") }.count == 3)
        #expect(fx.amazon.calls.filter { $0 == drive("PUT", "trash/E-1") }.count == 3)
        #expect(fx.clock.sleeps.filter { $0 >= 7 }.count >= 2)  // it honored Retry-After
        #expect(fx.amazon.node("E-1")?.status == "TRASH")
    }

    @Test func aWriteThatReachedAmazonBeforeTheAnswerWasLostCountsAsDone() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let attempts = Tally()
        fx.amazon.override { [amazon = fx.amazon] request in
            if request.method == "PUT", request.url.path == "/drive/v1/trash/E-1", attempts.next() == 1 {
                amazon.modify("E-1") { $0.status = "TRASH" }  // Amazon did it ...
                return .body(Data(), status: 503)  // ... but the answer says otherwise
            }
            return nil
        }
        let result = try await fx.apply(plan.id)
        #expect(result.status == .applied && result.succeeded == 4 && result.skipped == 0)
        #expect(fx.amazon.calls.filter { $0 == drive("PUT", "trash/E-1") }.count == 1)  // not trashed twice
        let step = try fx.step(plan, "E-1")
        #expect(step.state == .done && step.result?.hasPrefix("Already done") == true)
        #expect(try fx.catalogItem("E-1") == nil)
    }

    @Test func throttlingThatDoesNotEndStopsTheRunAtThatStep() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.override { request in
            request.method == "PUT" && request.url.path == "/drive/v1/trash/E-4" ? .body(Data(), status: 429) : nil
        }
        let result = try await fx.apply(plan.id)
        #expect(result.succeeded == 1 && result.failed == 1)
        #expect(result.status == .partlyApplied && result.remaining == 3)  // the failed step and two waiting
        guard case .failure(let text)? = result.stopReason else {
            Issue.record("expected a failure, got \(String(describing: result.stopReason))")
            return
        }
        #expect(text == "Amazon is limiting requests (HTTP 429)")
        #expect(result.message.contains("Stopped at step 2: Amazon is limiting requests (HTTP 429). 3 steps remain; run apply again to resume."))
        #expect(fx.amazon.calls.filter { $0 == drive("PUT", "trash/E-4") }.count == 1 + PlanRunner.maxRetries)
        #expect(try fx.step(plan, "E-4").state == .failed)
        #expect(try fx.step(plan, "E-2").state == .pending)
    }

    @Test func anExpiredSessionStopsTheRunAndALaterApplyResumesWhereItStopped() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let signedOut = Switch(true)
        fx.amazon.override { request in
            signedOut.isOn && request.url.path == "/drive/v1/nodes/E-4" ? .body(Data(), status: 401) : nil
        }
        let first = try await fx.apply(plan.id)
        #expect(first.stopReason == .sessionExpired)
        #expect(first.succeeded == 1 && first.failed == 1 && first.remaining == 3 && first.status == .partlyApplied)
        #expect(first.message.contains("session expired at step 2") && first.message.contains("Sign in again"))
        let stopped = try fx.step(plan, "E-4")
        #expect(stopped.state == .failed && stopped.result == "Amazon session expired: sign in again")

        signedOut.isOn = false
        let second = try await fx.apply(plan.id)
        #expect(second.status == .applied && second.succeeded == 3 && second.stopReason == nil)
        // The step that was done before the stop is not done again.
        #expect(fx.amazon.calls.filter { $0 == drive("PUT", "trash/E-3") }.count == 1)
        #expect(try fx.reload(plan).summary.states.done == 4)
    }

    @Test func aWriteThatAmazonAcceptedButDidNotCarryOutStopsTheRunAndIsRetriedLater() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.ignoreWrites()
        let first = try await fx.apply(plan.id)
        #expect(first.succeeded == 0 && first.failed == 1 && first.status == .partlyApplied)
        guard case .failure(let text)? = first.stopReason else {
            Issue.record("expected a failure")
            return
        }
        #expect(text.contains("accepted the change but did not carry it out"))
        #expect(fx.writeCalls.count == 1)  // it stopped at the first unexpected answer
        #expect(try fx.catalogItemIDs().count == 5)  // nothing was removed locally

        fx.amazon.ignoreWrites(false)
        let second = try await fx.apply(plan.id)
        #expect(second.status == .applied && second.succeeded == 4)
    }

    @Test func aRefusedStepStopsTheRunUntilItsCauseIsGone() async throws {
        // Renaming a node to a name that is taken is refused with 409 and stops the run.
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Rename then trash", catalogRefreshedAt: nil,
            steps: [
                PlanStepDraft(
                    operation: .rename, nodeId: "E-1", fromValue: "broken1.jpg", toValue: "broken2.png", reason: "test",
                    before: PlanSnapshot(parent: "F-PHONE", name: "broken1.jpg", status: "AVAILABLE")),
                PlanStepDraft(
                    operation: .trash, nodeId: "G-1", reason: "test",
                    before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE")),
            ])
        let first = try await fx.apply(plan.id)
        #expect(first.succeeded == 0 && first.failed == 1 && first.remaining == 2 && first.status == .partlyApplied)
        guard case .failure(let text)? = first.stopReason else {
            Issue.record("expected a failure")
            return
        }
        #expect(text.contains("already exists"))
        #expect(fx.amazon.node("G-1")?.status == "AVAILABLE")  // the run did not go on

        fx.amazon.modify("E-2") { $0.name = "somewhere-else.png" }
        let second = try await fx.apply(plan.id)
        #expect(second.status == .applied && second.succeeded == 2)
        #expect(fx.amazon.node("E-1")?.name == "broken2.png")
        #expect(fx.amazon.node("G-1")?.status == "TRASH")
    }

    @Test func atMostTheConfiguredNumberOfStepsRunPerCall() async throws {
        var config = Config()
        config.amazonWrites.maxStepsPerApply = 2
        let fx = try PlanFixture(config: config)
        let plan = try fx.makePlan()

        let first = try await fx.apply(plan.id)
        #expect(first.succeeded == 2 && first.remaining == 2 && first.status == .partlyApplied)
        #expect(first.stopReason == .stepLimit(2))
        #expect(first.message.contains("The limit is 2 steps per run, so 2 steps remain"))
        #expect(first.message.contains("config set-writes --max-steps"))
        #expect(try fx.reload(plan).summary.states == PlanStateCounts(pending: 2, done: 2))
        #expect(fx.amazon.node("E-3")?.status == "TRASH" && fx.amazon.node("E-4")?.status == "TRASH")
        #expect(fx.amazon.node("E-1")?.status == "AVAILABLE" && fx.amazon.node("E-2")?.status == "AVAILABLE")

        let second = try await fx.apply(plan.id)
        #expect(second.succeeded == 2 && second.remaining == 0 && second.status == .applied)
        #expect(second.stopReason == nil)  // the last step used up the limit exactly, and nothing is left
        await #expect(throws: PlanError.self) { _ = try await fx.apply(plan.id) }
    }

    @Test func skippedStepsDoNotCountAgainstTheLimit() async throws {
        var config = Config()
        config.amazonWrites.maxStepsPerApply = 2
        let fx = try PlanFixture(config: config)
        let plan = try fx.makePlan()
        fx.amazon.modify("E-3") { $0.name = "changed.jpg" }
        let result = try await fx.apply(plan.id)
        #expect(result.skipped == 1 && result.succeeded == 2 && result.remaining == 1)
        #expect(result.stopReason == .stepLimit(2))
    }

    @Test func aLimitOfZeroLiftsTheCap() async throws {
        var config = Config()
        config.amazonWrites.maxStepsPerApply = 0
        let fx = try PlanFixture(config: config)
        let result = try await fx.apply(try fx.makePlan().id)
        #expect(result.succeeded == 4 && result.status == .applied)
    }

    @Test func untickedStepsAreNeverApplied() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        try fx.plans.setIncluded(false, planId: plan.id, matching: PlanStepFilter(group: "Pictures/Phone"))
        let result = try await fx.apply(plan.id)
        #expect(result.succeeded == 2 && result.remaining == 0 && result.status == .applied)
        #expect(fx.amazon.node("E-1")?.status == "AVAILABLE" && fx.amazon.node("E-2")?.status == "AVAILABLE")
        #expect(fx.amazon.node("E-3")?.status == "TRASH" && fx.amazon.node("E-4")?.status == "TRASH")
        #expect(try fx.catalogItemIDs() == ["E-1", "E-2", "G-1"])
        let left = try fx.step(plan, "E-1")
        #expect(left.state == .pending && !left.included)
    }

    @Test func aPlanWithNothingTickedCannotBeApplied() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        try fx.plans.setIncluded(false, planId: plan.id, matching: PlanStepFilter())
        await #expect(throws: PlanError.nothingToDo("Every step of plan \(plan.id) is unticked, so there is nothing to apply.")) {
            _ = try await fx.apply(plan.id)
        }
    }

    @Test func aPlanThatWasAppliedCannotBeAppliedAgainAndAnUnknownOneIsReported() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        _ = try await fx.apply(plan.id)
        await #expect(throws: PlanError.self) { _ = try await fx.apply(plan.id) }
        await #expect(throws: PlanError.notFound(77)) { _ = try await fx.apply(77) }
    }

    @Test func aRunCanBeStoppedBetweenTwoSteps() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let stop = Switch()
        let result = try await fx.apply(plan.id, isCancelled: { stop.isOn }, progress: { _ in stop.isOn = true })
        #expect(result.stopReason == .cancelled && result.succeeded == 1 && result.remaining == 3)
        #expect(result.status == .partlyApplied)
        #expect(result.message.contains("Stopped on request"))
        stop.isOn = false
        let resumed = try await fx.apply(plan.id)
        #expect(resumed.succeeded == 3 && resumed.status == .applied)
    }

    @Test func aPlanThatIsStoppedBeforeItsFirstStepStaysADraft() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let result = try await fx.apply(plan.id, isCancelled: { true })
        #expect(result.stopReason == .cancelled && result.succeeded == 0)
        #expect(result.status == .draft)
        #expect(fx.amazon.calls.isEmpty)
    }

    @Test func progressNamesTheStepThatIsAboutToRun() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let lines = Collected<PlanProgress>()
        _ = try await fx.apply(plan.id, progress: { lines.add($0) })
        let all = lines.items
        #expect(all.count == 4 && all.map(\.done) == [0, 1, 2, 3] && all.allSatisfy { $0.total == 4 && $0.kind == .apply })
        #expect(all.first?.current == "trash empty-root.jpg")
    }

    @Test func aCutOffRunIsRecognisedAndItsLastWriteIsNotRepeated() async throws {
        // A plan left in the `applying` state, whose first node is already in the trash: the write
        // happened, the process died before the step was marked done.
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        try fx.plans.setStatus(planId: plan.id, .applying)
        fx.amazon.modify("E-3") { $0.status = "TRASH" }
        let result = try await fx.apply(plan.id)
        #expect(result.status == .applied && result.succeeded == 4 && result.skipped == 0)
        #expect(fx.amazon.calls.filter { $0 == drive("PUT", "trash/E-3") }.isEmpty)
        #expect(try fx.step(plan, "E-3").result?.hasPrefix("Already done") == true)
    }

    @Test func aRunningDownloadOrOrganizeKeepsApplyAndUndoAway() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let download = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        await #expect(throws: DownloadError.alreadyRunning) { _ = try await fx.apply(plan.id) }
        #expect(fx.amazon.calls.isEmpty)  // no request, not even a read
        #expect(try fx.reload(plan).status == .draft)
        download.release()

        let applied = try await fx.apply(plan.id)
        #expect(applied.status == .applied)
        let organize = try #require(try RunLock(path: fx.paths.downloadLockURL.path))
        let callsBefore = fx.amazon.calls.count
        await #expect(throws: DownloadError.alreadyRunning) { _ = try await fx.undo(plan.id) }
        #expect(fx.amazon.calls.count == callsBefore)
        organize.release()
        #expect(try await fx.undo(plan.id).status == .undone)
    }

    @Test func aRunHoldsTheLockWhileItWorksAndLetsGoAfterwards() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let heldDuringRun = Tally()
        let statusDuringRun = Collected<PlanStatus>()
        let probe: @Sendable () -> Bool = { [path = fx.paths.downloadLockURL.path] in (try? RunLock(path: path)) == nil }
        _ = try await fx.apply(plan.id, progress: { _ in
            if probe() { heldDuringRun.next() }
            if let stored = try? fx.plans.plan(id: plan.id) { statusDuringRun.add(stored.status) }
        })
        #expect(heldDuringRun.count == 4)  // at every step
        #expect(statusDuringRun.items.allSatisfy { $0 == .applying })
        #expect(!probe())  // free again
        let undo = Tally()
        _ = try await fx.undo(plan.id, progress: { _ in if probe() { undo.next() } })
        #expect(undo.count == 4 && !probe())
    }

    @Test func aFailedRunReleasesTheLockToo() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        fx.amazon.override { _ in .body(Data(), status: 401) }
        let result = try await fx.apply(plan.id)
        #expect(result.stopReason == .sessionExpired)
        #expect(try RunLock(path: fx.paths.downloadLockURL.path) != nil)
    }

    @Test func errorTextsNeverCarryCookieValues() async throws {
        let fx = try PlanFixture()
        let runner = PlanRunner(store: fx.store, client: try fx.amazon.client(), config: fx.config, environment: fx.environment)
        let text = runner.text(for: DownloadError.network("cookie: session-token=\(fx.amazon.secretToken); id=\(fx.amazon.sessionID)"))
        #expect(!text.contains(fx.amazon.secretToken) && !text.contains(fx.amazon.sessionID))
        #expect(text.contains("[redacted]"))
    }

    @Test func aStepWithoutItsDataFailsInsteadOfGuessing() async throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Broken", catalogRefreshedAt: nil,
            steps: [PlanStepDraft(operation: .move, nodeId: "G-1", reason: "no destination",
                                  before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE"))])
        let result = try await fx.apply(plan.id)
        #expect(result.failed == 1 && result.status == .partlyApplied)
        #expect(try fx.step(plan, "G-1").result == "Step 1 has no destination folder.")
        #expect(fx.writeCalls.isEmpty)
    }
}

// MARK: Other operations, and undo

@Suite("Undoing a plan")
struct PlanUndoTests {
    /// A plan that makes a folder, moves, renames and describes a file, and trashes another.
    private func mixedPlan(_ fx: PlanFixture) throws -> Plan {
        try fx.plans.create(
            planner: "test", title: "Mixed", catalogRefreshedAt: nil,
            steps: [
                PlanStepDraft(operation: .createFolder, parentId: "ROOT", toValue: "Archive", reason: "new folder"),
                PlanStepDraft(
                    operation: .move, nodeId: "G-1", parentId: "F-DOCS", fromValue: "Pictures/Phone", toValue: "Docs",
                    reason: "move", before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE")),
                PlanStepDraft(
                    operation: .rename, nodeId: "G-1", fromValue: "good.jpg", toValue: "great.jpg", reason: "rename",
                    before: PlanSnapshot(parent: "F-DOCS", name: "good.jpg", status: "AVAILABLE")),
                PlanStepDraft(
                    operation: .describe, nodeId: "G-1", toValue: "family trip", reason: "describe",
                    before: PlanSnapshot(parent: "F-DOCS", name: "great.jpg", status: "AVAILABLE")),
                PlanStepDraft(
                    operation: .trash, nodeId: "E-1", reason: "empty",
                    before: PlanSnapshot(parent: "F-PHONE", name: "broken1.jpg", status: "AVAILABLE", md5: emptyContentMD5),
                    catalogItem: PlanFixture.items()[0]),
            ])
    }

    @Test func everyOperationIsCarriedOutWithItsLocalCatalogFollowUp() async throws {
        let fx = try PlanFixture()
        let plan = try mixedPlan(fx)
        let result = try await fx.apply(plan.id)
        #expect(result.succeeded == 5 && result.status == .applied)

        let archive = try #require(fx.amazon.node("N-NEW1"))
        #expect(archive.name == "Archive" && archive.kind == "FOLDER" && archive.parents == ["ROOT"])
        let file = try #require(fx.amazon.node("G-1"))
        #expect(file.parents == ["F-DOCS"] && file.name == "great.jpg" && file.description == "family trip")
        #expect(fx.amazon.node("E-1")?.status == "TRASH")

        // Catalog: the new folder, the new parent and name, the trashed item gone.
        #expect(try fx.catalogFolder("N-NEW1") == CloudFolder(nodeId: "N-NEW1", name: "Archive", parentId: "ROOT"))
        let item = try #require(try fx.catalogItem("G-1"))
        #expect(item.parentId == "F-DOCS" && item.name == "great.jpg")
        #expect(try fx.catalogItem("E-1") == nil)

        // What undo will need.
        let steps = try fx.steps(plan)
        #expect(steps[0].createdNodeId == "N-NEW1" && !steps[0].reusedExisting)
        #expect(steps[1].inverseValue == "F-PHONE" && steps[1].after?.parent == "F-DOCS")
        #expect(steps[2].inverseValue == "good.jpg" && steps[2].after?.name == "great.jpg")
        #expect(steps[3].inverseValue == "")
    }

    @Test func undoReversesEveryStepLastFirstAndPutsTheCatalogBack() async throws {
        let fx = try PlanFixture()
        let plan = try mixedPlan(fx)
        _ = try await fx.apply(plan.id)
        let before = fx.amazon.calls.count
        let result = try await fx.undo(plan.id)

        #expect(result.kind == .undo && result.succeeded == 5 && result.skipped == 0 && result.remaining == 0)
        #expect(result.status == .undone && result.stopReason == nil && result.message == "Reversed 5 steps.")
        // Amazon is as it was.
        let file = try #require(fx.amazon.node("G-1"))
        #expect(file.parents == ["F-PHONE"] && file.name == "good.jpg" && file.description == nil)
        #expect(fx.amazon.node("E-1")?.status == "AVAILABLE")
        #expect(fx.amazon.node("N-NEW1")?.status == "TRASH")  // the folder is trashed, never purged
        // The catalog is as it was.
        #expect(try fx.catalogItem("G-1") == PlanFixture.items()[4])
        #expect(try fx.catalogItem("E-1") == PlanFixture.items()[0])
        #expect(try fx.catalogFolder("N-NEW1") == nil)
        // The write calls of the undo, in reverse plan order.
        let undoWrites = Array(fx.amazon.calls.dropFirst(before)).filter { !$0.hasPrefix("GET ") }
        #expect(undoWrites == [
            drive("POST", "trash/E-1/restore"), drive("PATCH", "nodes/G-1"), drive("PATCH", "nodes/G-1"),
            drive("POST", "nodes/F-PHONE/children"), drive("PUT", "trash/N-NEW1"),
        ])
        let stored = try fx.reload(plan)
        #expect(stored.status == .undone && stored.undoneAt != nil)
        #expect(stored.summary.states.undone == 5 && stored.summary.reversible == 0)
        #expect(try fx.steps(plan).allSatisfy { $0.state == .undone })
        // An undone plan is finished: it can neither be undone nor applied again.
        await #expect(throws: PlanError.self) { _ = try await fx.undo(plan.id) }
        await #expect(throws: PlanError.self) { _ = try await fx.apply(plan.id) }
    }

    @Test func aFolderThatWasAlreadyThereBeforeThePlanStaysWhenThePlanIsUndone() async throws {
        var nodes = PlanFixture.nodes()
        nodes.append(.folder("F-ARCH", "Archive", in: "ROOT"))
        let fx = try PlanFixture(nodes: nodes)
        let plan = try fx.plans.create(
            planner: "test", title: "Folder", catalogRefreshedAt: nil,
            steps: [PlanStepDraft(operation: .createFolder, parentId: "ROOT", toValue: "Archive", reason: "new folder")])
        let applied = try await fx.apply(plan.id)
        #expect(applied.succeeded == 1 && applied.status == .applied)
        let step = try #require(try fx.steps(plan).first)
        #expect(step.createdNodeId == "F-ARCH" && step.reusedExisting)
        #expect(step.result == "The folder was already there, so it was used.")
        #expect(!fx.writeCalls.contains(drive("POST", "nodes")))  // no second folder was made

        let undone = try await fx.undo(plan.id)
        #expect(undone.succeeded == 1 && undone.status == .undone)
        #expect(fx.amazon.node("F-ARCH")?.status == "AVAILABLE")  // it was not the plan's folder
        #expect(!fx.writeCalls.contains { $0.hasPrefix("PUT") })
    }

    @Test func undoDoesNotTouchWhatChangedAfterThePlanWasApplied() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        _ = try await fx.apply(plan.id)
        // After the plan: E-2 was renamed (still in the trash), and E-1 was restored by hand.
        fx.amazon.modify("E-2") { $0.name = "mine-now.png" }
        fx.amazon.modify("E-1") { $0.status = "AVAILABLE" }

        let first = try await fx.undo(plan.id)
        #expect(first.succeeded == 3 && first.skipped == 1 && first.status == .partlyApplied && first.remaining == 1)
        #expect(first.message.contains("1 step could not be reversed because the item changed in Amazon since the plan was applied"))
        #expect(fx.amazon.node("E-2")?.status == "TRASH")  // left alone
        let blocked = try fx.step(plan, "E-2")
        #expect(blocked.state == .done)
        #expect(blocked.result?.hasPrefix("Not undone: it changed since the plan was applied: it was renamed from") == true)
        #expect(try fx.step(plan, "E-1").result == "Already back as before.")
        #expect(try fx.catalogItemIDs() == ["E-1", "E-3", "E-4", "G-1"])  // E-2 is still gone locally
        // A plan that was undone in part cannot be applied again, or the undone steps would run twice.
        await #expect(throws: PlanError.self) { _ = try await fx.apply(plan.id) }

        // Once the cause is gone, another undo finishes the job.
        fx.amazon.modify("E-2") { $0.name = "broken2.png" }
        let second = try await fx.undo(plan.id)
        #expect(second.succeeded == 1 && second.status == .undone)
        #expect(fx.amazon.node("E-2")?.status == "AVAILABLE")
        #expect(try fx.catalogItemIDs() == ["E-1", "E-2", "E-3", "E-4", "G-1"])
    }

    @Test func undoReversesOnlyTheStepsThatWereDoneInAPartlyAppliedPlan() async throws {
        var config = Config()
        config.amazonWrites.maxStepsPerApply = 2
        let fx = try PlanFixture(config: config)
        let plan = try fx.makePlan()
        let applied = try await fx.apply(plan.id)
        #expect(applied.status == .partlyApplied && applied.succeeded == 2)

        let result = try await fx.undo(plan.id)
        #expect(result.succeeded == 2 && result.remaining == 0 && result.status == .undone)
        #expect(fx.amazon.node("E-3")?.status == "AVAILABLE" && fx.amazon.node("E-4")?.status == "AVAILABLE")
        // The two steps that never ran stay pending, and the plan is closed.
        let summary = try fx.reload(plan).summary
        #expect(summary.states == PlanStateCounts(pending: 2, undone: 2))
        await #expect(throws: PlanError.self) { _ = try await fx.apply(plan.id) }
        #expect(try fx.catalogItemIDs() == ["E-1", "E-2", "E-3", "E-4", "G-1"])
    }

    @Test func aPlanThatWasNeverAppliedHasNothingToUndo() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        await #expect(throws: PlanError.self) { _ = try await fx.undo(plan.id) }
        await #expect(throws: PlanError.notFound(9)) { _ = try await fx.undo(9) }
        #expect(fx.amazon.calls.isEmpty)
    }

    @Test func undoStopsWhenTheSessionExpiresAndContinuesLater() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        _ = try await fx.apply(plan.id)
        let signedOut = Switch(true)
        fx.amazon.override { request in
            signedOut.isOn && request.url.path == "/drive/v1/nodes/E-4" ? .body(Data(), status: 401) : nil
        }
        // Undo runs last step first: E-2, E-1, then E-4 hits the expired session.
        let first = try await fx.undo(plan.id)
        #expect(first.stopReason == .sessionExpired && first.succeeded == 2 && first.failed == 1)
        #expect(first.status == .partlyApplied && first.remaining == 2)
        #expect(try fx.step(plan, "E-4").state == .done)  // still done: it has not been undone
        #expect(try fx.step(plan, "E-4").result?.hasPrefix("Not undone: Amazon session expired") == true)

        signedOut.isOn = false
        let second = try await fx.undo(plan.id)
        #expect(second.succeeded == 2 && second.status == .undone)
        for id in ["E-1", "E-2", "E-3", "E-4"] { #expect(fx.amazon.node(id)?.status == "AVAILABLE") }
    }

    @Test func aRenameThatAnInterruptedRunMadeIsUndoneToTheNameBeforeThePlan() async throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Rename", catalogRefreshedAt: nil,
            steps: [PlanStepDraft(
                operation: .rename, nodeId: "G-1", fromValue: "good.jpg", toValue: "great.jpg", reason: "rename",
                before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE"))])
        // The rename reached Amazon, then the process died before the step was marked done.
        try fx.plans.setStatus(planId: plan.id, .applying)
        fx.amazon.modify("G-1") { $0.name = "great.jpg" }
        let applied = try await fx.apply(plan.id)
        #expect(applied.status == .applied && fx.writeCalls.isEmpty)
        #expect(try fx.step(plan, "G-1").inverseValue == "good.jpg")

        _ = try await fx.undo(plan.id)
        #expect(fx.amazon.node("G-1")?.name == "good.jpg")
    }

    @Test func aRenameIsNotUndoneOverANewerRename() async throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Rename", catalogRefreshedAt: nil,
            steps: [PlanStepDraft(
                operation: .rename, nodeId: "G-1", fromValue: "good.jpg", toValue: "great.jpg", reason: "rename",
                before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE"))])
        _ = try await fx.apply(plan.id)
        fx.amazon.modify("G-1") { $0.name = "newest.jpg" }
        let result = try await fx.undo(plan.id)
        #expect(result.succeeded == 0 && result.skipped == 1 && result.status == .partlyApplied)
        #expect(fx.amazon.node("G-1")?.name == "newest.jpg")
        #expect(try fx.catalogItem("G-1")?.name == "great.jpg")  // the catalog still shows the plan's name
    }

    @Test func aDescriptionIsNotUndoneOverANewerDescription() async throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Describe", catalogRefreshedAt: nil,
            steps: [PlanStepDraft(
                operation: .describe, nodeId: "G-1", toValue: "from the plan", reason: "describe",
                before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE"))])
        _ = try await fx.apply(plan.id)
        fx.amazon.modify("G-1") { $0.description = "written by hand" }
        let result = try await fx.undo(plan.id)
        #expect(result.skipped == 1 && fx.amazon.node("G-1")?.description == "written by hand")
        #expect(try fx.step(plan, "G-1").result == "Not undone: its description changed since the plan was applied.")
    }

    @Test func aFolderIsNotTrashedWhileALaterStepCouldNotBeUndone() async throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Folder and rename", catalogRefreshedAt: nil,
            steps: [
                PlanStepDraft(operation: .createFolder, parentId: "ROOT", toValue: "Archive", reason: "new folder"),
                PlanStepDraft(
                    operation: .rename, nodeId: "G-1", fromValue: "good.jpg", toValue: "great.jpg", reason: "rename",
                    before: PlanSnapshot(parent: "F-PHONE", name: "good.jpg", status: "AVAILABLE")),
            ])
        _ = try await fx.apply(plan.id)
        fx.amazon.modify("G-1") { $0.name = "newest.jpg" }
        let result = try await fx.undo(plan.id)
        #expect(result.succeeded == 0 && result.skipped == 2)
        #expect(fx.amazon.node("N-NEW1")?.status == "AVAILABLE")
        let folder = try #require(try fx.steps(plan).first)
        #expect(folder.state == .done && folder.result?.contains("a later step of the plan could not be undone") == true)
    }

    @Test func aRefreshFromALaggingSourceDoesNotBringBackWhatAPlanTrashed() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        _ = try await fx.apply(plan.id)
        let empty: Set<String> = ["E-1", "E-2", "E-3", "E-4"]
        #expect(try fx.catalogItemIDs().isDisjoint(with: empty))

        // The Amazon Photos app has not synced yet: its index still lists the trashed files.
        func refresh(after days: Double) throws {
            try CatalogRefresher(store: fx.store).refresh(
                from: StaticCatalog(items: PlanFixture.items(), folders: PlanFixture.folders),
                now: noonOct16.addingTimeInterval(days * 24 * 3600))
        }
        try refresh(after: 1)
        #expect(try fx.catalogItemIDs() == ["G-1"])

        // After the grace period the source is trusted again, for example after a restore on the website.
        try refresh(after: 15)
        #expect(try fx.catalogItemIDs() == Set(["G-1"]).union(empty))

        // An undone trash no longer keeps anything out.
        try refresh(after: 1)
        #expect(try fx.catalogItemIDs() == ["G-1"])
        _ = try await fx.undo(plan.id)
        try refresh(after: 2)
        #expect(try fx.catalogItemIDs() == Set(["G-1"]).union(empty))
    }
}
