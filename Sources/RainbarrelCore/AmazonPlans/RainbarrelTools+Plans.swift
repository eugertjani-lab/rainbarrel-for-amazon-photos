import Foundation

/// The answer of `plan_create_cleanup_empty`.
public struct PlanCreation: Codable, Sendable, Equatable {
    /// False when the catalog holds no empty file and no plan was made.
    public var created: Bool
    public var plan: Plan?
    public var message: String
}

/// A plan with a sample of its steps, the answer of `plan_show`.
public struct PlanDetail: Codable, Sendable, Equatable {
    public var plan: Plan
    /// The first steps in plan order.
    public var steps: [PlanStep]
    public var stepsShown: Int
    public var stepsTotal: Int
    public var message: String
}

extension RainbarrelTools {
    private var planService: PlanService { PlanService(paths: paths, environment: downloadEnvironment) }

    static let planNotice =
        "Nothing has been sent to Amazon. A plan is applied by the person who owns the library, in the app or with `rainbarrel apply <id>`."

    /// Make a draft plan that trashes the empty files of the catalog. Writes the draft to the state
    /// database and nothing else; Amazon is not contacted.
    public func planCreateCleanupEmpty() throws -> PlanCreation {
        let plan = try planService.createCleanupPlan()
        guard let plan else {
            return PlanCreation(created: false, plan: nil, message: "The catalog holds no empty file, so no plan was made.")
        }
        return PlanCreation(
            created: true, plan: plan,
            message: "Plan \(plan.id) is a draft: \(plan.summary.headline). \(Self.planNotice)")
    }

    /// A plan and a sample of its steps. Reads the state database only.
    public func planShow(id: Int64, sample: Int = PlanService.defaultStepSample) throws -> PlanDetail {
        let service = planService
        do {
            let plan = try service.plan(id: id)
            let count = min(max(sample, 0), PlanService.maxStepSample)
            let steps = try service.steps(planId: id, limit: count)
            return PlanDetail(
                plan: plan, steps: steps, stepsShown: steps.count, stepsTotal: plan.summary.totalSteps,
                message: "\(plan.summary.headline). Status: \(plan.status.text). \(Self.planNotice)")
        } catch let error as PlanError {
            throw ToolError(error.description)
        }
    }
}
