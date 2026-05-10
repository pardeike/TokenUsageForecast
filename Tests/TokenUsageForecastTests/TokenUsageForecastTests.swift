import Foundation
import Testing
@testable import TokenUsageForecast

@Test func defaultParametersMatchPrefixBacktestValues() {
    let p = ForecastParameters.defaults
    #expect(p.maxIdleGapInsideSessionMinutes == 12.6)
    #expect(p.mergeNearbyFutureSessionCandidatesMinutes == 27.2)
    #expect(p.burstThresholdPercentPerHour == 1.41)
    #expect(p.minimumGainForIntenseClusterPercent == 0.48)
    #expect(p.recencyHalfLifeHours == 60)
    #expect(p.linearSessionBlendPercent == 35.3)
    #expect(p.dailyRhythmStrengthPercent == 88.6)
    #expect(p.frequencyAccelerationPercent == 53.3)
    #expect(p.backgroundIdleDriftPercentPerDay == 12.1)
    #expect(p.forecastResolutionMinutes == 10)
    #expect(p.optimisticActivityScale == 0.335)
    #expect(p.pessimisticActivityScale == 2.53)
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

@Test func demoDataPrefixBacktestMostlyStaysInTunedRange() throws {
    let url = Bundle.module.url(forResource: "DemoQuotaData", withExtension: "json")!
    let snapshot = try UsageLimitSnapshot.load(from: url)

    var rows: [(prefix: Int, low: Double, high: Double)] = []
    for prefix in 60...100 {
        let sampleCount = max(2, Int((Double(snapshot.samples.count) * Double(prefix) / 100).rounded()))
        let samples = Array(snapshot.samples.prefix(sampleCount))
        let current = samples.last?.weeklyUsedPercent ?? snapshot.weeklyUsedPercent ?? 0
        let elapsed = samples.last?.offsetSeconds ?? samples.last?.offsetMinutes.map { $0 * 60 } ?? snapshot.elapsedWindowSeconds
        let prefixSnapshot = UsageLimitSnapshot(
            limitId: snapshot.limitId,
            limitName: snapshot.limitName,
            planType: snapshot.planType,
            weeklyWindowMinutes: snapshot.weeklyWindowMinutes,
            elapsedWindowSeconds: elapsed,
            weeklyUsedPercent: current,
            fiveHourUsedPercent: snapshot.fiveHourUsedPercent,
            samples: samples
        )
        let result = try TokenUsageForecaster().forecast(from: prefixSnapshot)
        rows.append((prefix, result.optimistic.finalUsedPercent, result.pessimistic.finalUsedPercent))
    }

    let corridorHits = rows.filter { row in
        row.low >= 90 && row.high >= 96 && row.high <= 148 && row.low <= row.high
    }.count
    let exactHits = rows.filter { row in
        row.low >= 94 && row.low <= 102 && row.high >= 140 && row.high <= 150
    }.count
    let finalRow = try #require(rows.last)

    #expect(corridorHits >= 37)
    #expect(exactHits >= 25)
    #expect(abs(finalRow.low - 103.8) < 0.2)
    #expect(abs(finalRow.high - 147.4) < 0.2)
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
