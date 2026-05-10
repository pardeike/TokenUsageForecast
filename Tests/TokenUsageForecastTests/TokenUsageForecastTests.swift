import Foundation
import Testing
@testable import TokenUsageForecast

@Test func defaultParametersMatchScreenshotValues() {
    let p = ForecastParameters.defaults
    #expect(p.maxIdleGapInsideSessionMinutes == 25)
    #expect(p.mergeNearbyFutureSessionCandidatesMinutes == 105)
    #expect(p.burstThresholdPercentPerHour == 2.75)
    #expect(p.minimumGainForIntenseClusterPercent == 1)
    #expect(p.recencyHalfLifeHours == 3)
    #expect(p.linearSessionBlendPercent == 14)
    #expect(p.dailyRhythmStrengthPercent == 20)
    #expect(p.frequencyAccelerationPercent == 41)
    #expect(p.backgroundIdleDriftPercentPerDay == 11)
    #expect(p.forecastResolutionMinutes == 70)
    #expect(p.optimisticActivityScale == 1.30)
    #expect(p.pessimisticActivityScale == 1.50)
    #expect(p.capForecastAt100Percent == false)
}

@Test func demoDataProducesForecasts() throws {
    let url = Bundle.module.url(forResource: "DemoQuotaData", withExtension: "json")!
    let snapshot = try UsageLimitSnapshot.load(from: url)
    let result = try TokenUsageForecaster().forecast(from: snapshot)

    #expect(result.currentUsedPercent == 72)
    #expect(result.cutoffMinutes > 7_000)
    #expect(result.endMinutes == 10_080)
    #expect(result.sessions.count > 0)
    #expect(!result.optimistic.points.isEmpty)
    #expect(!result.pessimistic.points.isEmpty)
    #expect(result.optimistic.finalUsedPercent >= result.currentUsedPercent)
    #expect(result.pessimistic.finalUsedPercent >= result.optimistic.finalUsedPercent)
    #expect(result.linearReferenceFinalPercent >= result.currentUsedPercent)
}

@Test func forecastCanBeCappedAt100Percent() throws {
    let url = Bundle.module.url(forResource: "DemoQuotaData", withExtension: "json")!
    let snapshot = try UsageLimitSnapshot.load(from: url)
    var parameters = ForecastParameters.defaults
    parameters.capForecastAt100Percent = true
    let result = try TokenUsageForecaster(parameters: parameters).forecast(from: snapshot)
    #expect((result.optimistic.points.map(\.usedPercent).max() ?? 0) <= 100)
    #expect((result.pessimistic.points.map(\.usedPercent).max() ?? 0) <= 100)
}
