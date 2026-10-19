import Foundation

/// How carefully changes to the Amazon library are applied. Stored in `config.json` under
/// `amazonWrites`; every field is optional there and falls back to the default.
public struct AmazonWritesConfig: Codable, Sendable, Equatable {
    /// One apply call performs at most this many steps, so that a first run can be checked on the
    /// Amazon Photos website before a larger one follows.
    public static let defaultMaxStepsPerApply = 50
    public static let maxStepsLimit = 1_000_000

    /// The most steps that one `apply` call performs. 0 means no limit.
    public var maxStepsPerApply: Int

    public init(maxStepsPerApply: Int = AmazonWritesConfig.defaultMaxStepsPerApply) {
        self.maxStepsPerApply = maxStepsPerApply
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxStepsPerApply = (try? container.decodeIfPresent(Int.self, forKey: .maxStepsPerApply)) ?? nil
            ?? Self.defaultMaxStepsPerApply
    }

    /// Check every field. Used when settings are changed; a hand-edited file with bad values is
    /// handled by `normalized` instead.
    public func validate() throws {
        guard (0...Self.maxStepsLimit).contains(maxStepsPerApply) else {
            throw ToolError("maxStepsPerApply must be 0 (no limit) or a number up to \(Self.maxStepsLimit).")
        }
    }

    /// The same settings with every value forced into its valid range. A negative number falls back
    /// to the default, because a limit that was typed wrongly must never lift the cap.
    public var normalized: AmazonWritesConfig {
        var copy = self
        if copy.maxStepsPerApply < 0 { copy.maxStepsPerApply = Self.defaultMaxStepsPerApply }
        copy.maxStepsPerApply = min(copy.maxStepsPerApply, Self.maxStepsLimit)
        return copy
    }

    /// The number of steps one apply call performs, or nil when there is no limit.
    public var stepLimit: Int? {
        let value = normalized.maxStepsPerApply
        return value == 0 ? nil : value
    }

    /// The settings as short lines for `config show` and status screens.
    public var summaryLines: [String] {
        let value = normalized.maxStepsPerApply
        return ["maxStepsPerApply:        " + (value == 0 ? "0 (no limit)" : String(value))]
    }
}
