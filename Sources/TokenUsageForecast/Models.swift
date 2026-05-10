import Foundation

/// A raw quota snapshot with the same shape as the JSON emitted by the quota sampler.
/// Percent values are intentionally not clamped: forecasts may exceed 100%.
public struct UsageLimitSnapshot: Codable, Equatable, Sendable {
    public var limitId: String?
    public var limitName: String?
    public var planType: String?
    public var weeklyWindowMinutes: Double?
    public var elapsedWindowMinutes: Double?
    public var elapsedWindowSeconds: Double?
    public var weeklyUsedPercent: Double?
    public var fiveHourUsedPercent: Double?
    public var fiveHourResetOffsetMinutes: Double?
    public var fiveHourResetOffsetSeconds: Double?
    public var samples: [UsageSample]

    public init(
        limitId: String? = nil,
        limitName: String? = nil,
        planType: String? = nil,
        weeklyWindowMinutes: Double? = nil,
        elapsedWindowMinutes: Double? = nil,
        elapsedWindowSeconds: Double? = nil,
        weeklyUsedPercent: Double? = nil,
        fiveHourUsedPercent: Double? = nil,
        fiveHourResetOffsetMinutes: Double? = nil,
        fiveHourResetOffsetSeconds: Double? = nil,
        samples: [UsageSample]
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.planType = planType
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.elapsedWindowMinutes = elapsedWindowMinutes
        self.elapsedWindowSeconds = elapsedWindowSeconds
        self.weeklyUsedPercent = weeklyUsedPercent
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourResetOffsetMinutes = fiveHourResetOffsetMinutes
        self.fiveHourResetOffsetSeconds = fiveHourResetOffsetSeconds
        self.samples = samples
    }
}

public extension UsageLimitSnapshot {
    static func load(from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> UsageLimitSnapshot {
        try decoder.decode(UsageLimitSnapshot.self, from: Data(contentsOf: url))
    }
}

public struct UsageSample: Codable, Equatable, Sendable {
    public var offsetMinutes: Double?
    public var offsetSeconds: Double?
    public var weeklyUsedPercent: Double

    public init(offsetMinutes: Double? = nil, offsetSeconds: Double? = nil, weeklyUsedPercent: Double) {
        self.offsetMinutes = offsetMinutes
        self.offsetSeconds = offsetSeconds
        self.weeklyUsedPercent = weeklyUsedPercent
    }
}

/// Tunable knobs for the forecasting model.
/// Defaults mirror the values shown in the experiment screenshot.
public struct ForecastParameters: Codable, Equatable, Sendable {
    /// Optional backtest/forecast cutoff in minutes from the beginning of the weekly window.
    /// `nil` means use the latest observed elapsed minute.
    public var cutoffMinutes: Double?

    /// Maximum gap between token increases that still belongs to one coding session / cluster.
    public var maxIdleGapInsideSessionMinutes: Double

    /// Merge future session candidates whose predicted starts are close to each other.
    public var mergeNearbyFutureSessionCandidatesMinutes: Double

    /// Session intensity threshold, in weekly-used percent per hour.
    public var burstThresholdPercentPerHour: Double

    /// Minimum cluster gain to mark it intense, even if the hourly rate is lower.
    public var minimumGainForIntenseClusterPercent: Double

    /// Recency half-life in hours. Lower values make recent sessions dominate.
    public var recencyHalfLifeHours: Double

    /// Blend between linear extrapolation and session-pattern replay, as percent linear.
    public var linearSessionBlendPercent: Double

    /// Strength of same-time-next-day echoes, as percent.
    public var dailyRhythmStrengthPercent: Double

    /// Positive values shorten repeated-session gaps; negative values lengthen them.
    public var frequencyAccelerationPercent: Double

    /// Background drift added independently of clusters, in percent per day.
    public var backgroundIdleDriftPercentPerDay: Double

    /// Forecast step size in minutes.
    public var forecastResolutionMinutes: Double

    /// Activity multiplier for the optimistic curve, e.g. `1.30` means 1.30×.
    public var optimisticActivityScale: Double

    /// Activity multiplier for the pessimistic curve, e.g. `1.50` means 1.50×.
    public var pessimisticActivityScale: Double

    /// Include observed samples after the cutoff in the result. Useful for backtesting.
    public var includeHeldoutSamples: Bool

    /// Include predicted session candidates in the result.
    public var includeCandidateDetails: Bool

    /// Clamp forecast values to 100%. The intended default is `false` because quota use can exceed 100%.
    public var capForecastAt100Percent: Bool

    public init(
        cutoffMinutes: Double? = nil,
        maxIdleGapInsideSessionMinutes: Double = 25,
        mergeNearbyFutureSessionCandidatesMinutes: Double = 105,
        burstThresholdPercentPerHour: Double = 2.75,
        minimumGainForIntenseClusterPercent: Double = 1,
        recencyHalfLifeHours: Double = 3,
        linearSessionBlendPercent: Double = 14,
        dailyRhythmStrengthPercent: Double = 20,
        frequencyAccelerationPercent: Double = 41,
        backgroundIdleDriftPercentPerDay: Double = 11,
        forecastResolutionMinutes: Double = 70,
        optimisticActivityScale: Double = 1.30,
        pessimisticActivityScale: Double = 1.50,
        includeHeldoutSamples: Bool = true,
        includeCandidateDetails: Bool = true,
        capForecastAt100Percent: Bool = false
    ) {
        self.cutoffMinutes = cutoffMinutes
        self.maxIdleGapInsideSessionMinutes = maxIdleGapInsideSessionMinutes
        self.mergeNearbyFutureSessionCandidatesMinutes = mergeNearbyFutureSessionCandidatesMinutes
        self.burstThresholdPercentPerHour = burstThresholdPercentPerHour
        self.minimumGainForIntenseClusterPercent = minimumGainForIntenseClusterPercent
        self.recencyHalfLifeHours = recencyHalfLifeHours
        self.linearSessionBlendPercent = linearSessionBlendPercent
        self.dailyRhythmStrengthPercent = dailyRhythmStrengthPercent
        self.frequencyAccelerationPercent = frequencyAccelerationPercent
        self.backgroundIdleDriftPercentPerDay = backgroundIdleDriftPercentPerDay
        self.forecastResolutionMinutes = forecastResolutionMinutes
        self.optimisticActivityScale = optimisticActivityScale
        self.pessimisticActivityScale = pessimisticActivityScale
        self.includeHeldoutSamples = includeHeldoutSamples
        self.includeCandidateDetails = includeCandidateDetails
        self.capForecastAt100Percent = capForecastAt100Percent
    }

    /// Defaults from the user's tuned screenshot.
    public static let defaults = ForecastParameters()

    /// Initial defaults from the first HTML prototype, useful when comparing results.
    public static let htmlPrototypeDefaults = ForecastParameters(
        maxIdleGapInsideSessionMinutes: 120,
        mergeNearbyFutureSessionCandidatesMinutes: 90,
        burstThresholdPercentPerHour: 3,
        minimumGainForIntenseClusterPercent: 3,
        recencyHalfLifeHours: 24,
        linearSessionBlendPercent: 28,
        dailyRhythmStrengthPercent: 58,
        frequencyAccelerationPercent: 25,
        backgroundIdleDriftPercentPerDay: 0,
        forecastResolutionMinutes: 10,
        optimisticActivityScale: 0.65,
        pessimisticActivityScale: 1.45
    )
}

public struct ForecastPoint: Codable, Equatable, Sendable {
    public var offsetMinutes: Double
    public var usedPercent: Double

    public init(offsetMinutes: Double, usedPercent: Double) {
        self.offsetMinutes = offsetMinutes
        self.usedPercent = usedPercent
    }
}

public struct SessionProfilePoint: Codable, Equatable, Sendable {
    public var relativeMinutes: Double
    public var cumulativeFraction: Double

    public init(relativeMinutes: Double, cumulativeFraction: Double) {
        self.relativeMinutes = relativeMinutes
        self.cumulativeFraction = cumulativeFraction
    }
}

public struct UsageChangeEvent: Codable, Equatable, Sendable {
    public var offsetMinutes: Double
    public var usedPercent: Double
    public var deltaPercent: Double

    public init(offsetMinutes: Double, usedPercent: Double, deltaPercent: Double) {
        self.offsetMinutes = offsetMinutes
        self.usedPercent = usedPercent
        self.deltaPercent = deltaPercent
    }
}

public struct UsageSession: Codable, Equatable, Sendable {
    public var startMinutes: Double
    public var endMinutes: Double
    public var rawSpanMinutes: Double
    public var durationMinutes: Double
    public var gainPercent: Double
    public var intensityPercentPerHour: Double
    public var isIntense: Bool
    public var events: [UsageChangeEvent]
    public var profile: [SessionProfilePoint]

    public init(
        startMinutes: Double,
        endMinutes: Double,
        rawSpanMinutes: Double,
        durationMinutes: Double,
        gainPercent: Double,
        intensityPercentPerHour: Double,
        isIntense: Bool,
        events: [UsageChangeEvent],
        profile: [SessionProfilePoint]
    ) {
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.rawSpanMinutes = rawSpanMinutes
        self.durationMinutes = durationMinutes
        self.gainPercent = gainPercent
        self.intensityPercentPerHour = intensityPercentPerHour
        self.isIntense = isIntense
        self.events = events
        self.profile = profile
    }
}

public enum CandidateSource: String, Codable, Equatable, Sendable {
    case daily
    case interval
    case continuation
}

public enum ForecastScenarioName: String, Codable, Equatable, Sendable {
    case optimistic
    case pessimistic
}

public struct FutureSessionCandidate: Codable, Equatable, Sendable {
    public var startMinutes: Double
    public var durationMinutes: Double
    public var gainPercent: Double
    public var rawGainPercent: Double
    public var score: Double
    public var source: CandidateSource
    public var sourceLabel: String
    public var mergedCount: Int
    public var scenario: ForecastScenarioName
    public var profile: [SessionProfilePoint]

    public init(
        startMinutes: Double,
        durationMinutes: Double,
        gainPercent: Double,
        rawGainPercent: Double,
        score: Double,
        source: CandidateSource,
        sourceLabel: String,
        mergedCount: Int,
        scenario: ForecastScenarioName,
        profile: [SessionProfilePoint]
    ) {
        self.startMinutes = startMinutes
        self.durationMinutes = durationMinutes
        self.gainPercent = gainPercent
        self.rawGainPercent = rawGainPercent
        self.score = score
        self.source = source
        self.sourceLabel = sourceLabel
        self.mergedCount = mergedCount
        self.scenario = scenario
        self.profile = profile
    }
}

public struct SlopeStats: Codable, Equatable, Sendable {
    public var periodSlopePercentPerMinute: Double
    public var observedSlopePercentPerMinute: Double
    public var recentWindowSlopePercentPerMinute: Double
    public var weightedSlopePercentPerMinute: Double
    public var linearReferenceSlopePercentPerMinute: Double
    public var optimisticSlopePercentPerMinute: Double
    public var pessimisticSlopePercentPerMinute: Double
    public var linearReferenceFinalPercent: Double

    public init(
        periodSlopePercentPerMinute: Double,
        observedSlopePercentPerMinute: Double,
        recentWindowSlopePercentPerMinute: Double,
        weightedSlopePercentPerMinute: Double,
        linearReferenceSlopePercentPerMinute: Double,
        optimisticSlopePercentPerMinute: Double,
        pessimisticSlopePercentPerMinute: Double,
        linearReferenceFinalPercent: Double
    ) {
        self.periodSlopePercentPerMinute = periodSlopePercentPerMinute
        self.observedSlopePercentPerMinute = observedSlopePercentPerMinute
        self.recentWindowSlopePercentPerMinute = recentWindowSlopePercentPerMinute
        self.weightedSlopePercentPerMinute = weightedSlopePercentPerMinute
        self.linearReferenceSlopePercentPerMinute = linearReferenceSlopePercentPerMinute
        self.optimisticSlopePercentPerMinute = optimisticSlopePercentPerMinute
        self.pessimisticSlopePercentPerMinute = pessimisticSlopePercentPerMinute
        self.linearReferenceFinalPercent = linearReferenceFinalPercent
    }
}

public struct ScenarioForecast: Codable, Equatable, Sendable {
    public var scenario: ForecastScenarioName
    public var points: [ForecastPoint]
    public var candidates: [FutureSessionCandidate]
    public var slopePercentPerMinute: Double
    public var finalUsedPercent: Double
    public var crossing100Minutes: Double?
    public var sessionGainFinalPercent: Double

    public init(
        scenario: ForecastScenarioName,
        points: [ForecastPoint],
        candidates: [FutureSessionCandidate],
        slopePercentPerMinute: Double,
        finalUsedPercent: Double,
        crossing100Minutes: Double?,
        sessionGainFinalPercent: Double
    ) {
        self.scenario = scenario
        self.points = points
        self.candidates = candidates
        self.slopePercentPerMinute = slopePercentPerMinute
        self.finalUsedPercent = finalUsedPercent
        self.crossing100Minutes = crossing100Minutes
        self.sessionGainFinalPercent = sessionGainFinalPercent
    }
}

public struct UsageForecastResult: Codable, Equatable, Sendable {
    public var parameters: ForecastParameters
    public var cutoffMinutes: Double
    public var endMinutes: Double
    public var currentUsedPercent: Double
    public var linearReference: [ForecastPoint]
    public var linearReferenceFinalPercent: Double
    public var linearReferenceCrossing100Minutes: Double?
    public var optimistic: ScenarioForecast
    public var pessimistic: ScenarioForecast
    public var heldoutSamples: [ForecastPoint]
    public var changeEvents: [UsageChangeEvent]
    public var sessions: [UsageSession]
    public var slopes: SlopeStats

    public init(
        parameters: ForecastParameters,
        cutoffMinutes: Double,
        endMinutes: Double,
        currentUsedPercent: Double,
        linearReference: [ForecastPoint],
        linearReferenceFinalPercent: Double,
        linearReferenceCrossing100Minutes: Double?,
        optimistic: ScenarioForecast,
        pessimistic: ScenarioForecast,
        heldoutSamples: [ForecastPoint],
        changeEvents: [UsageChangeEvent],
        sessions: [UsageSession],
        slopes: SlopeStats
    ) {
        self.parameters = parameters
        self.cutoffMinutes = cutoffMinutes
        self.endMinutes = endMinutes
        self.currentUsedPercent = currentUsedPercent
        self.linearReference = linearReference
        self.linearReferenceFinalPercent = linearReferenceFinalPercent
        self.linearReferenceCrossing100Minutes = linearReferenceCrossing100Minutes
        self.optimistic = optimistic
        self.pessimistic = pessimistic
        self.heldoutSamples = heldoutSamples
        self.changeEvents = changeEvents
        self.sessions = sessions
        self.slopes = slopes
    }
}

public enum ForecastError: Error, Equatable, Sendable, LocalizedError {
    case noUsableSamples

    public var errorDescription: String? {
        switch self {
        case .noUsableSamples:
            "No usable samples were found in the quota snapshot."
        }
    }
}
