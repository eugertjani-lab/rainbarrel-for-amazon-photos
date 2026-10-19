import Foundation
import Testing
@testable import RainbarrelCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: The empty-file planner

@Suite("Empty file planner")
struct EmptyFilePlannerTests {
    @Test func proposesOneTrashStepForEveryEmptyFileAndNothingElse() throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        #expect(plan.planner == "cleanup-empty" && plan.title == "Trash empty files")
        #expect(plan.status == .draft)
        #expect(plan.catalogRefreshedAt == Date(timeIntervalSince1970: 1_800_000_000))

        let steps = try fx.steps(plan)
        // Folder by folder (the top level sorts first, then Docs, then Pictures/Phone), then by name.
        #expect(steps.map(\.nodeId) == ["E-3", "E-4", "E-1", "E-2"])
        #expect(steps.map(\.position) == [1, 2, 3, 4])
        #expect(steps.allSatisfy { $0.operation == .trash && $0.state == .pending && $0.included })
        #expect(steps.allSatisfy { $0.reason == "empty file (0 bytes)" && $0.size == 0 })
        #expect(!steps.contains { $0.nodeId == "G-1" })
    }

    @Test func recordsWhatTheCatalogSaidAboutEachItem() throws {
        let fx = try PlanFixture()
        let step = try fx.step(try fx.makePlan(), "E-1")
        #expect(step.before == PlanSnapshot(parent: "F-PHONE", name: "broken1.jpg", status: "AVAILABLE", md5: emptyContentMD5))
        #expect(step.catalogItem == PlanFixture.items()[0])
        #expect(step.fromValue == "Pictures/Phone/broken1.jpg")
        #expect(step.after == nil && step.result == nil)
    }

    @Test func groupsByTheFolderPathTheWayTheDownloadTargetsAreBuilt() throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        #expect(try fx.step(plan, "E-1").groupLabel == "Pictures/Phone")
        #expect(try fx.step(plan, "E-2").groupLabel == "Pictures/Phone")
        #expect(try fx.step(plan, "E-4").groupLabel == "Docs")
        #expect(try fx.step(plan, "E-3").groupLabel == "(top level)")
        let groups = try fx.plans.groups(planId: plan.id)
        #expect(groups.map(\.label) == ["Pictures/Phone", "(top level)", "Docs"])
        #expect(groups.map(\.included) == [2, 1, 1])
    }

    @Test func aFolderThatCannotBeTracedToTheRootIsLabelledUnknown() throws {
        let items = [
            CloudItem(nodeId: "E-9", kind: .file, name: "lost.jpg", md5: emptyContentMD5, size: 0, takenAt: t2019, parentId: "F-GONE")
        ]
        let fx = try PlanFixture(items: items)
        let step = try fx.step(try fx.makePlan(), "E-9")
        #expect(step.groupLabel == "(unknown folder)")
        #expect(step.fromValue == "(unknown folder)/lost.jpg")
    }

    @Test func includesEmptyLivePhotoVideosAndLeavesNonEmptyOnesAlone() throws {
        let items = [
            CloudItem(nodeId: "P-1", kind: .file, name: "IMG_1.HEIC", md5: String(repeating: "b", count: 32), size: 50, takenAt: t2019, parentId: "F-PHONE"),
            CloudItem(nodeId: "LV-1", kind: .liveVideo, name: "IMG_1.MOV", md5: emptyContentMD5, size: 0, takenAt: t2019, parentId: "P-1"),
            CloudItem(nodeId: "LV-2", kind: .liveVideo, name: "IMG_2.MOV", md5: String(repeating: "c", count: 32), size: 9, takenAt: t2019, parentId: "P-1"),
        ]
        let fx = try PlanFixture(items: items)
        let steps = try fx.steps(try fx.makePlan())
        #expect(steps.map(\.nodeId) == ["LV-1"])
        // A Live Photo video sits in its photo's folder.
        #expect(steps.first?.groupLabel == "Pictures/Phone")
        #expect(steps.first?.before.parent == "P-1")
    }

    @Test func makesNoPlanWhenNothingIsEmpty() throws {
        let fx = try PlanFixture(items: [PlanFixture.items()[4]])
        #expect(try fx.plans.createPlan(using: EmptyFileCleanupPlanner()) == nil)
        #expect(try fx.plans.plans().isEmpty)
    }
}

// MARK: Storing plans

@Suite("Plan store")
struct PlanStoreTests {
    @Test func theSummaryCountsStepsBytesAndTicks() throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        let s = plan.summary
        #expect(s.totalSteps == 4 && s.includedSteps == 4 && s.excludedSteps == 0)
        #expect(s.operations == [PlanOperationCount(operation: .trash, included: 4, excluded: 0, includedBytes: 0, excludedBytes: 0)])
        #expect(s.states.pending == 4 && s.states.total == 4)
        #expect(s.remainingToApply == 4 && s.reversible == 0)
        #expect(s.headline == "Trash 4 items (0 B)")
    }

    @Test func bytesAreSummedPerOperationAndTick() throws {
        let fx = try PlanFixture()
        let plan = try fx.plans.create(
            planner: "test", title: "Mixed", catalogRefreshedAt: nil,
            steps: [
                PlanStepDraft(operation: .trash, nodeId: "G-1", reason: "r", size: 100),
                PlanStepDraft(operation: .trash, nodeId: "E-1", reason: "r", size: 40),
                PlanStepDraft(operation: .rename, nodeId: "E-2", toValue: "x.png", reason: "r"),
                PlanStepDraft(operation: .createFolder, parentId: "ROOT", toValue: "New", reason: "r"),
            ])
        try fx.plans.setIncluded(false, planId: plan.id, position: 2)
        let s = try fx.reload(plan).summary
        #expect(s.count(of: .trash) == PlanOperationCount(operation: .trash, included: 1, excluded: 1, includedBytes: 100, excludedBytes: 40))
        #expect(s.count(of: .rename)?.included == 1 && s.count(of: .createFolder)?.included == 1)
        #expect(s.count(of: .move) == nil)
        #expect(s.includedSteps == 3 && s.excludedSteps == 1 && s.includedBytes == 100 && s.excludedBytes == 40)
        #expect(s.operations.map(\.operation) == [.createFolder, .rename, .trash])
        #expect(s.headline == "Create 1 folder, rename 1 item, trash 1 item (100 B); 1 unticked")
    }

    @Test func aStepOrAGroupCanBeUntickedAndTickedAgain() throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        #expect(try fx.plans.setIncluded(false, planId: plan.id, position: 1))
        #expect(try fx.plans.setIncluded(false, planId: plan.id, position: 1) == false)  // already unticked
        #expect(try fx.plans.setIncluded(false, planId: plan.id, matching: PlanStepFilter(operation: .trash, group: "Pictures/Phone")) == 2)
        var summary = try fx.reload(plan).summary
        #expect(summary.includedSteps == 1 && summary.excludedSteps == 3 && summary.remainingToApply == 1)
        #expect(summary.headline == "Trash 1 item (0 B); 3 unticked")
        #expect(try fx.plans.setIncluded(true, planId: plan.id, matching: PlanStepFilter(group: "Pictures/Phone")) == 2)
        summary = try fx.reload(plan).summary
        #expect(summary.includedSteps == 3 && summary.excludedSteps == 1)
        #expect(try fx.plans.steps(planId: plan.id, filter: PlanStepFilter(included: false)).map(\.nodeId) == ["E-3"])
    }

    @Test func aPlanThatWasAppliedCannotBeEdited() async throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        _ = try await fx.apply(plan.id)
        #expect(throws: PlanError.self) { try fx.plans.setIncluded(false, planId: plan.id, position: 1) }
        #expect(throws: PlanError.notFound(999)) { try fx.plans.setIncluded(false, planId: 999, position: 1) }
    }

    @Test func stepsCanBeFilteredSearchedAndPaged() throws {
        let fx = try PlanFixture()
        let plan = try fx.makePlan()
        #expect(try fx.plans.steps(planId: plan.id, limit: 2).map(\.position) == [1, 2])
        #expect(try fx.plans.steps(planId: plan.id, limit: 2, offset: 2).map(\.position) == [3, 4])
        #expect(try fx.plans.steps(planId: plan.id, offset: 3).map(\.position) == [4])
        #expect(try fx.plans.steps(planId: plan.id, filter: PlanStepFilter(search: "PHONE")).map(\.nodeId) == ["E-1", "E-2"])
        #expect(try fx.plans.steps(planId: plan.id, filter: PlanStepFilter(search: "50%")).isEmpty)  // % is not a wildcard
        #expect(try fx.plans.count(planId: plan.id, filter: PlanStepFilter(state: .pending)) == 4)
        #expect(try fx.plans.count(planId: plan.id, filter: PlanStepFilter(state: .done)) == 0)
    }

    @Test func plansAreListedNewestFirst() throws {
        let fx = try PlanFixture()
        let first = try fx.makePlan()
        let second = try fx.makePlan()
        #expect(try fx.plans.plans().map(\.id) == [second.id, first.id])
        #expect(try fx.plans.plans(limit: 1).map(\.id) == [second.id])
        #expect(try fx.plans.plan(id: 12345) == nil)
    }

    @Test func plansSurviveReopeningTheDatabase() throws {
        let dir = try TempDirectory()
        let path = dir.path("state.sqlite")
        let id: Int64
        do {
            let store = try StateStore(path: path)
            try CatalogRefresher(store: store).refresh(
                from: StaticCatalog(items: PlanFixture.items(), folders: PlanFixture.folders))
            id = try #require(try PlanStore(store: store).createPlan(using: EmptyFileCleanupPlanner())).id
        }
        let reopened = PlanStore(store: try StateStore(path: path))
        let plan = try #require(try reopened.plan(id: id))
        #expect(plan.summary.totalSteps == 4)
        #expect(try reopened.steps(planId: id).first?.catalogItem != nil)
    }

    @Test func aPlanNeedsAtLeastOneStep() throws {
        let fx = try PlanFixture()
        #expect(throws: PlanError.self) {
            try fx.plans.create(planner: "x", title: "x", steps: [])
        }
    }
}

// MARK: Configuration

@Suite("Amazon writes configuration")
struct AmazonWritesConfigTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func theDefaultCapIsFiftySteps() throws {
        #expect(Config().amazonWrites.maxStepsPerApply == 50)
        #expect(Config().amazonWrites.stepLimit == 50)
        #expect(try decode("{}").amazonWrites == AmazonWritesConfig())
        #expect(try decode(#"{"amazonWrites":{}}"#).amazonWrites.maxStepsPerApply == 50)
    }

    @Test func aDamagedSectionFallsBackToTheDefault() throws {
        #expect(try decode(#"{"amazonWrites":"many"}"#).amazonWrites.maxStepsPerApply == 50)
        #expect(try decode(#"{"amazonWrites":{"maxStepsPerApply":"lots"}}"#).amazonWrites.maxStepsPerApply == 50)
        #expect(try decode(#"{"amazonWrites":{"maxStepsPerApply":-3}}"#).amazonWrites.stepLimit == 50)
    }

    @Test func zeroLiftsTheCap() throws {
        let config = try decode(#"{"amazonWrites":{"maxStepsPerApply":0}}"#)
        #expect(config.amazonWrites.stepLimit == nil)
        #expect(config.amazonWrites.summaryLines == ["maxStepsPerApply:        0 (no limit)"])
    }

    @Test func settingsAreCheckedWhenTheyAreChanged() throws {
        try AmazonWritesConfig(maxStepsPerApply: 0).validate()
        try AmazonWritesConfig(maxStepsPerApply: 500).validate()
        #expect(throws: ToolError.self) { try AmazonWritesConfig(maxStepsPerApply: -1).validate() }
        #expect(throws: ToolError.self) { try AmazonWritesConfig(maxStepsPerApply: 2_000_000).validate() }
        #expect(AmazonWritesConfig(maxStepsPerApply: 5_000_000).normalized.maxStepsPerApply == 1_000_000)
    }

    @Test func theSettingIsStoredInConfigJson() throws {
        let dir = try TempDirectory()
        let store = ConfigStore(url: dir.url.appendingPathComponent("config.json"))
        var config = Config(driveRoot: "/Volumes/X")
        config.amazonWrites.maxStepsPerApply = 12
        try store.save(config)
        #expect(try store.load().amazonWrites.maxStepsPerApply == 12)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(text.contains("\"amazonWrites\""))
    }
}

// MARK: Service and tools

@Suite("Plan service and tools")
struct PlanServiceTests {
    private func stubbedEnvironment(_ fx: PlanFixture) -> DownloadEnvironment {
        DownloadEnvironment(
            clock: fx.clock.clock, random: { 0.5 },
            sessionConfiguration: {
                let configuration = AmazonClient.defaultConfiguration()
                configuration.protocolClasses = [StubURLProtocol.self]
                return configuration
            }, timeouts: fx.amazon.timeouts)
    }

    @Test func theServiceMakesAppliesAndUndoesAPlanThroughTheStateFile() async throws {
        let fx = try PlanFixture()
        let paths = fx.paths
        let store = try StateStore(path: paths.stateURL.path)
        try CatalogRefresher(store: store).refresh(
            from: StaticCatalog(items: PlanFixture.items(), folders: PlanFixture.folders))
        let service = PlanService(paths: paths, environment: stubbedEnvironment(fx))

        let plan = try #require(try service.createCleanupPlan())
        #expect(try service.plans().map(\.id) == [plan.id])
        #expect(try service.plan(id: plan.id).summary.totalSteps == 4)
        #expect(try service.steps(planId: plan.id, limit: 2).count == 2)
        #expect(try service.groups(planId: plan.id).count == 3)

        let config = Config(amazonHost: fx.amazon.host)
        let applied = try await service.apply(
            planId: plan.id, config: config, session: fx.amazon.session, sessionStore: MemorySessionStore())
        #expect(applied.status == .applied && applied.succeeded == 4)
        #expect(fx.amazon.node("E-1")?.status == "TRASH")
        #expect(try service.plan(id: plan.id).status == .applied)

        let undone = try await service.undo(planId: plan.id, config: config, session: fx.amazon.session)
        #expect(undone.status == .undone && undone.succeeded == 4)
        #expect(fx.amazon.node("E-1")?.status == "AVAILABLE")
    }

    @Test func theServiceRefusesAnUnusableSessionBeforeAnyRequest() async throws {
        let fx = try PlanFixture()
        let store = try StateStore(path: fx.paths.stateURL.path)
        try CatalogRefresher(store: store).refresh(from: StaticCatalog(items: PlanFixture.items(), folders: PlanFixture.folders))
        let service = PlanService(paths: fx.paths, environment: stubbedEnvironment(fx))
        let plan = try #require(try service.createCleanupPlan())
        let expired = StoredSession(host: fx.amazon.host, cookies: [], savedAt: noonOct16)
        await #expect(throws: DownloadError.sessionExpired) {
            _ = try await service.apply(planId: plan.id, config: Config(amazonHost: fx.amazon.host), session: expired)
        }
        #expect(fx.amazon.calls.isEmpty)
    }

    @Test func anEmptyCatalogIsNotPlannedFrom() throws {
        let dir = try TempDirectory()
        let service = PlanService(paths: AppPaths(dataDirectory: dir.url))
        #expect(throws: ToolError.self) { try service.createCleanupPlan() }
        #expect(throws: PlanError.notFound(1)) { try service.plan(id: 1) }
    }

    /// The fixture owns the temporary data directory, so it has to stay alive as long as the registry.
    private func registry(items: [CloudItem]) async throws -> (fixture: ToolsFixture, tools: RainbarrelToolRegistry) {
        let fixture = try ToolsFixture(catalog: items)
        _ = try await fixture.tools.refreshCatalog()
        return (fixture, RainbarrelToolRegistry(tools: fixture.tools))
    }

    @Test func theAssistantCanMakeAndReadAPlanButCannotApplyOne() async throws {
        let names = RainbarrelToolRegistry.definitions.map(\.name)
        #expect(names.contains("plan_create_cleanup_empty") && names.contains("plan_show"))
        #expect(!names.contains { $0.contains("apply") || $0.contains("undo") })
        #expect(RainbarrelToolRegistry.definitions.first { $0.name == "plan_show" }?.readOnly == true)
        // Making a draft writes to Rainbarrel's own database, so it is not a read-only tool.
        #expect(RainbarrelToolRegistry.definitions.first { $0.name == "plan_create_cleanup_empty" }?.readOnly == false)

        let (fixture, tools) = try await registry(items: PlanFixture.items())
        defer { withExtendedLifetime(fixture) {} }
        let made = tools.call(name: "plan_create_cleanup_empty", arguments: nil)
        #expect(!made.isError, "\(made.text)")
        let creation = try JSONDecoder.iso8601.decode(PlanCreation.self, from: Data(made.text.utf8))
        #expect(creation.created)
        let plan = try #require(creation.plan)
        #expect(plan.summary.includedSteps == 4 && plan.status == .draft)
        #expect(creation.message.contains("Nothing has been sent to Amazon"))

        let shown = tools.call(name: "plan_show", arguments: ["id": .int(Int(plan.id)), "sample": .int(2)])
        #expect(!shown.isError)
        let detail = try JSONDecoder.iso8601.decode(PlanDetail.self, from: Data(shown.text.utf8))
        #expect(detail.stepsShown == 2 && detail.stepsTotal == 4 && detail.steps.count == 2)
        #expect(detail.plan.id == plan.id)
        #expect(detail.steps.allSatisfy { $0.operation == .trash && $0.state == .pending })
    }

    @Test func theToolsReportProblemsInPlainWords() async throws {
        let (fixture, tools) = try await registry(items: [PlanFixture.items()[4]])
        defer { withExtendedLifetime(fixture) {} }
        let none = tools.call(name: "plan_create_cleanup_empty", arguments: nil)
        #expect(!none.isError)
        #expect(try JSONDecoder.iso8601.decode(PlanCreation.self, from: Data(none.text.utf8)).created == false)

        let missing = tools.call(name: "plan_show", arguments: ["id": .int(42)])
        #expect(missing.isError && missing.text.contains("no plan with id 42"))
        #expect(tools.call(name: "plan_show", arguments: nil).isError)
        #expect(tools.call(name: "plan_show", arguments: ["id": .int(0)]).isError)
        #expect(tools.call(name: "plan_apply", arguments: ["id": .int(1)]).isError)  // there is no such tool
    }
}
