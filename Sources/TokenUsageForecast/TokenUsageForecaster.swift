import Foundation

public struct TokenUsageForecaster: Sendable {
    public var parameters: ForecastParameters

    public init(parameters: ForecastParameters = .defaults) {
        self.parameters = parameters
    }

    public func forecast(from snapshot: UsageLimitSnapshot) throws -> UsageForecastResult {
        let data = normalize(snapshot)
        guard !data.samples.isEmpty else { throw ForecastError.noUsableSamples }

        let endMinutes = data.weeklyWindowMinutes
        let requestedCutoff = parameters.cutoffMinutes ?? data.elapsedWindowMinutes
        let firstT = data.samples[0].offsetMinutes
        let cutoff = clamp(requestedCutoff, firstT, min(data.elapsedWindowMinutes, endMinutes))
        let trainSamples = samples(upTo: cutoff, in: data.samples)
        let currentY = value(at: cutoff, samples: data.samples, fallback: data.weeklyUsedPercent)
        let events = changeEvents(trainSamples)
        let sessions = detectSessions(events, parameters: parameters)
        let slopes = slopeStats(samples: trainSamples, cutoff: cutoff, currentY: currentY, parameters: parameters, weeklyWindowMinutes: endMinutes)

        let optimisticMode = ForecastMode(
            name: .optimistic,
            quantile: 0.38,
            gapQuantile: 0.62,
            gapFactor: 1.16,
            accelSensitivity: 0.22,
            intervalStrength: 0.72,
            continuationStrength: 0.30,
            continuationDelayFactor: 0.42,
            activityScale: parameters.optimisticActivityScale,
            linearScale: 0.86
        )
        let pessimisticMode = ForecastMode(
            name: .pessimistic,
            quantile: 0.78,
            gapQuantile: 0.40,
            gapFactor: 0.84,
            accelSensitivity: 0.58,
            intervalStrength: 1.16,
            continuationStrength: 1.05,
            continuationDelayFactor: 0.22,
            activityScale: parameters.pessimisticActivityScale,
            linearScale: 1.16
        )

        let optimistic = makeForecast(sessions: sessions, events: events, cutoff: cutoff, endMinutes: endMinutes, currentY: currentY, parameters: parameters, slopes: slopes, mode: optimisticMode)
        let pessimistic = makeForecast(sessions: sessions, events: events, cutoff: cutoff, endMinutes: endMinutes, currentY: currentY, parameters: parameters, slopes: slopes, mode: pessimisticMode)
        let linear = makeLinearReference(cutoff: cutoff, endMinutes: endMinutes, currentY: currentY, parameters: parameters, slopes: slopes)

        var heldout: [ForecastPoint] = []
        if parameters.includeHeldoutSamples {
            heldout = data.samples
                .filter { $0.offsetMinutes >= cutoff && $0.offsetMinutes <= data.elapsedWindowMinutes }
                .map { ForecastPoint(offsetMinutes: $0.offsetMinutes, usedPercent: $0.usedPercent) }
            if let first = heldout.first, first.offsetMinutes > cutoff {
                heldout.insert(ForecastPoint(offsetMinutes: cutoff, usedPercent: currentY), at: 0)
            }
        }

        return UsageForecastResult(
            parameters: parameters,
            cutoffMinutes: cutoff,
            endMinutes: endMinutes,
            currentUsedPercent: currentY,
            linearReference: linear,
            linearReferenceFinalPercent: linear.last?.usedPercent ?? currentY,
            linearReferenceCrossing100Minutes: firstCrossing(linear),
            optimistic: optimistic,
            pessimistic: pessimistic,
            heldoutSamples: heldout,
            changeEvents: events,
            sessions: sessions,
            slopes: slopes
        )
    }
}

private struct NormalizedSnapshot: Sendable {
    var weeklyWindowMinutes: Double
    var elapsedWindowMinutes: Double
    var weeklyUsedPercent: Double
    var samples: [NormalizedSample]
}

private struct NormalizedSample: Equatable, Sendable {
    var offsetMinutes: Double
    var offsetSeconds: Double
    var usedPercent: Double
}

private struct ForecastMode: Sendable {
    var name: ForecastScenarioName
    var quantile: Double
    var gapQuantile: Double
    var gapFactor: Double
    var accelSensitivity: Double
    var intervalStrength: Double
    var continuationStrength: Double
    var continuationDelayFactor: Double
    var activityScale: Double
    var linearScale: Double
}

private func normalize(_ raw: UsageLimitSnapshot) -> NormalizedSnapshot {
    let normalizedSamples = raw.samples.compactMap { sample -> NormalizedSample? in
        let t: Double
        if let offsetMinutes = sample.offsetMinutes, offsetMinutes.isFinite {
            t = offsetMinutes
        } else if let offsetSeconds = sample.offsetSeconds, offsetSeconds.isFinite {
            t = offsetSeconds / 60
        } else {
            return nil
        }

        let seconds: Double
        if let offsetSeconds = sample.offsetSeconds, offsetSeconds.isFinite {
            seconds = offsetSeconds
        } else {
            seconds = t * 60
        }

        let y = sample.weeklyUsedPercent
        guard t.isFinite, y.isFinite else { return nil }
        return NormalizedSample(offsetMinutes: t, offsetSeconds: seconds, usedPercent: y)
    }
    .sorted { lhs, rhs in
        if lhs.offsetMinutes != rhs.offsetMinutes { return lhs.offsetMinutes < rhs.offsetMinutes }
        return lhs.usedPercent < rhs.usedPercent
    }

    let weeklyWindow = raw.weeklyWindowMinutes ?? 10_080
    let elapsed = raw.elapsedWindowMinutes
        ?? raw.elapsedWindowSeconds.map { $0 / 60 }
        ?? normalizedSamples.last?.offsetMinutes
        ?? 0
    let weeklyUsed = raw.weeklyUsedPercent ?? normalizedSamples.last?.usedPercent ?? 0

    return NormalizedSnapshot(
        weeklyWindowMinutes: weeklyWindow,
        elapsedWindowMinutes: elapsed,
        weeklyUsedPercent: weeklyUsed,
        samples: normalizedSamples
    )
}

private func value(at offsetMinutes: Double, samples: [NormalizedSample], fallback: Double = 0) -> Double {
    guard !samples.isEmpty else { return fallback }
    var lo = 0
    var hi = samples.count - 1
    var answer = -1
    while lo <= hi {
        let mid = (lo + hi) >> 1
        if samples[mid].offsetMinutes <= offsetMinutes {
            answer = mid
            lo = mid + 1
        } else {
            hi = mid - 1
        }
    }
    if answer < 0 { return samples[0].usedPercent }
    return samples[answer].usedPercent
}

private func samples(upTo cutoff: Double, in samples: [NormalizedSample]) -> [NormalizedSample] {
    var out = samples.filter { $0.offsetMinutes <= cutoff }
    let y = value(at: cutoff, samples: samples, fallback: samples.first?.usedPercent ?? 0)
    if out.isEmpty || out[out.count - 1].offsetMinutes < cutoff {
        out.append(NormalizedSample(offsetMinutes: cutoff, offsetSeconds: cutoff * 60, usedPercent: y))
    }
    return out
}

private func changeEvents(_ samples: [NormalizedSample]) -> [UsageChangeEvent] {
    guard samples.count >= 2 else { return [] }
    var events: [UsageChangeEvent] = []
    var lastY = samples[0].usedPercent
    for point in samples.dropFirst() {
        let dy = point.usedPercent - lastY
        if dy > 1e-9 {
            events.append(UsageChangeEvent(offsetMinutes: point.offsetMinutes, usedPercent: point.usedPercent, deltaPercent: dy))
        }
        lastY = point.usedPercent
    }
    return events
}

private func finalizeSession(start: Double, end: Double, gain: Double, events: [UsageChangeEvent], parameters: ForecastParameters) -> UsageSession {
    let rawSpan = max(0, end - start)
    let minDuration = max(20, min(180, parameters.maxIdleGapInsideSessionMinutes * 0.6))
    let duration = max(rawSpan, minDuration)
    let intensity = gain / max(duration, 1) * 60
    let high = intensity >= parameters.burstThresholdPercentPerHour || gain >= parameters.minimumGainForIntenseClusterPercent

    var cumulative = 0.0
    var profile: [SessionProfilePoint] = [SessionProfilePoint(relativeMinutes: 0, cumulativeFraction: 0)]
    for event in events {
        cumulative += event.deltaPercent
        let rtRaw = event.offsetMinutes - start
        let rt = rawSpan > 0 ? clamp(rtRaw, 0, duration) : max(3, duration * 0.35)
        profile.append(SessionProfilePoint(relativeMinutes: rt, cumulativeFraction: clamp(cumulative / gain, 0, 1)))
    }
    if (profile.last?.relativeMinutes ?? 0) < duration {
        profile.append(SessionProfilePoint(relativeMinutes: duration, cumulativeFraction: 1))
    }

    return UsageSession(
        startMinutes: start,
        endMinutes: end,
        rawSpanMinutes: rawSpan,
        durationMinutes: duration,
        gainPercent: gain,
        intensityPercentPerHour: intensity,
        isIntense: high,
        events: events,
        profile: profile
    )
}

private func detectSessions(_ events: [UsageChangeEvent], parameters: ForecastParameters) -> [UsageSession] {
    var sessions: [UsageSession] = []
    var start: Double?
    var end = 0.0
    var lastT = 0.0
    var gain = 0.0
    var currentEvents: [UsageChangeEvent] = []

    func closeCurrent() -> UsageSession? {
        guard let start else { return nil }
        return finalizeSession(start: start, end: end, gain: gain, events: currentEvents, parameters: parameters)
    }

    for event in events {
        if start == nil || event.offsetMinutes - lastT > parameters.maxIdleGapInsideSessionMinutes {
            if let closed = closeCurrent() { sessions.append(closed) }
            start = event.offsetMinutes
            end = event.offsetMinutes
            lastT = event.offsetMinutes
            gain = event.deltaPercent
            currentEvents = [event]
        } else {
            end = event.offsetMinutes
            lastT = event.offsetMinutes
            gain += event.deltaPercent
            currentEvents.append(event)
        }
    }

    if let closed = closeCurrent() { sessions.append(closed) }
    return sessions
}

private func recencyWeight(time t: Double, cutoff: Double, halfLifeMinutes: Double) -> Double {
    exp(-max(0, cutoff - t) / max(1, halfLifeMinutes) * log(2.0))
}

private func weightedQuantile(_ items: [(value: Double, weight: Double)], q: Double) -> Double {
    let arr = items
        .map { (value: $0.value, weight: max(0, $0.weight)) }
        .filter { $0.value.isFinite && $0.weight.isFinite && $0.weight > 0 }
        .sorted { $0.value < $1.value }
    guard !arr.isEmpty else { return 0 }
    let total = arr.reduce(0) { $0 + $1.weight }
    var acc = 0.0
    for item in arr {
        acc += item.weight
        if acc / total >= q { return item.value }
    }
    return arr[arr.count - 1].value
}

private func weightedAverage(_ items: [(value: Double, weight: Double)]) -> Double {
    var sw = 0.0
    var sv = 0.0
    for item in items {
        let w = max(0, item.weight)
        let v = item.value
        if w > 0, v.isFinite {
            sw += w
            sv += w * v
        }
    }
    return sw > 0 ? sv / sw : 0
}

private func slopeStats(samples: [NormalizedSample], cutoff: Double, currentY: Double, parameters: ForecastParameters, weeklyWindowMinutes: Double) -> SlopeStats {
    let first = samples.first ?? NormalizedSample(offsetMinutes: 0, offsetSeconds: 0, usedPercent: currentY)
    let periodSlope = cutoff > 0 ? currentY / cutoff : 0
    let observedSlope = cutoff > first.offsetMinutes ? (currentY - first.usedPercent) / (cutoff - first.offsetMinutes) : periodSlope
    let recWindow = max(60, parameters.recencyHalfLifeHours * 60)
    let yBack = value(at: max(0, cutoff - recWindow), samples: samples, fallback: first.usedPercent)
    let recentWindowSlope = (currentY - yBack) / min(recWindow, max(1, cutoff))

    var W = 0.0
    var Sx = 0.0
    var Sy = 0.0
    var Sxx = 0.0
    var Sxy = 0.0
    for point in samples where point.offsetMinutes <= cutoff {
        let w = recencyWeight(time: point.offsetMinutes, cutoff: cutoff, halfLifeMinutes: recWindow)
        W += w
        Sx += w * point.offsetMinutes
        Sy += w * point.usedPercent
        Sxx += w * point.offsetMinutes * point.offsetMinutes
        Sxy += w * point.offsetMinutes * point.usedPercent
    }
    let denom = W * Sxx - Sx * Sx
    let weightedSlope = denom != 0 ? max(0, (W * Sxy - Sx * Sy) / denom) : observedSlope
    let linearReferenceSlope = periodSlope
    let optimisticSlope = max(0, 0.60 * observedSlope + 0.25 * periodSlope + 0.15 * weightedSlope)
    let pessimisticSlope = max(0, 0.18 * periodSlope + 0.22 * weightedSlope + 0.60 * max(recentWindowSlope, weightedSlope))

    return SlopeStats(
        periodSlopePercentPerMinute: periodSlope,
        observedSlopePercentPerMinute: observedSlope,
        recentWindowSlopePercentPerMinute: recentWindowSlope,
        weightedSlopePercentPerMinute: weightedSlope,
        linearReferenceSlopePercentPerMinute: linearReferenceSlope,
        optimisticSlopePercentPerMinute: optimisticSlope,
        pessimisticSlopePercentPerMinute: pessimisticSlope,
        linearReferenceFinalPercent: currentY + linearReferenceSlope * max(0, weeklyWindowMinutes - cutoff)
    )
}

private func choosePrototype(sessions: [UsageSession], cutoff: Double, parameters: ForecastParameters, mode: ForecastMode) -> UsageSession? {
    let half = parameters.recencyHalfLifeHours * 60
    let weighted = sessions.map { session -> (session: UsageSession, weight: Double) in
        let highBoost = session.isIntense ? 1.25 : 1.0
        return (session, recencyWeight(time: session.endMinutes, cutoff: cutoff, halfLifeMinutes: half) * highBoost)
    }
    guard !weighted.isEmpty else { return nil }
    let targetGain = weightedQuantile(weighted.map { (value: $0.session.gainPercent, weight: $0.weight) }, q: mode.quantile)
    var best = weighted[0]
    var bestScore = Double.infinity
    for item in weighted {
        let score = abs(item.session.gainPercent - targetGain) / max(1, targetGain) - 0.08 * item.weight
        if score < bestScore {
            bestScore = score
            best = item
        }
    }
    return best.session
}

private func cloneProfile(from session: UsageSession?, fallbackDuration: Double) -> (duration: Double, profile: [SessionProfilePoint]) {
    guard let session else {
        let duration = fallbackDuration
        return (
            duration,
            [
                SessionProfilePoint(relativeMinutes: 0, cumulativeFraction: 0),
                SessionProfilePoint(relativeMinutes: duration * 0.35, cumulativeFraction: 0.45),
                SessionProfilePoint(relativeMinutes: duration * 0.70, cumulativeFraction: 0.82),
                SessionProfilePoint(relativeMinutes: duration, cumulativeFraction: 1)
            ]
        )
    }
    return (session.durationMinutes, session.profile)
}

private func profileValue(_ profile: [SessionProfilePoint], duration: Double, dt: Double) -> Double {
    if dt <= 0 { return 0 }
    if dt >= duration { return 1 }
    guard profile.count > 1 else { return dt >= duration ? 1 : 0 }
    for i in 1..<profile.count {
        let a = profile[i - 1]
        let b = profile[i]
        if dt <= b.relativeMinutes {
            let span = max(1e-6, b.relativeMinutes - a.relativeMinutes)
            let u = clamp((dt - a.relativeMinutes) / span, 0, 1)
            return a.cumulativeFraction + (b.cumulativeFraction - a.cumulativeFraction) * u
        }
    }
    return 1
}

private func candidateSourceLabel(_ source: CandidateSource) -> String {
    switch source {
    case .daily: "daily echo"
    case .interval: "interval rhythm"
    case .continuation: "active continuation"
    }
}

private func mergeCandidates(_ candidates: [FutureSessionCandidate], mergeGap: Double) -> [FutureSessionCandidate] {
    guard !candidates.isEmpty else { return [] }
    let sorted = candidates.sorted { $0.startMinutes < $1.startMinutes }
    var groups: [[FutureSessionCandidate]] = []
    var group = [sorted[0]]
    for candidate in sorted.dropFirst() {
        if candidate.startMinutes - (group.last?.startMinutes ?? candidate.startMinutes) <= mergeGap {
            group.append(candidate)
        } else {
            groups.append(group)
            group = [candidate]
        }
    }
    groups.append(group)

    return groups.map { group in
        let sw = group.reduce(0) { $0 + $1.score }
        let safeWeight = sw == 0 ? 1 : sw
        let start = group.reduce(0) { $0 + $1.startMinutes * $1.score } / safeWeight
        let duration = weightedAverage(group.map { (value: $0.durationMinutes, weight: $0.score) })
        let gainAverage = weightedAverage(group.map { (value: $0.gainPercent, weight: $0.score) })
        let gainMax = group.map(\.gainPercent).max() ?? 0
        let gain = 0.55 * gainMax + 0.45 * gainAverage
        let best = group.max { lhs, rhs in (lhs.score * lhs.gainPercent) < (rhs.score * rhs.gainPercent) } ?? group[0]
        let labels = orderedUnique(group.map { candidateSourceLabel($0.source) }).joined(separator: " + ")
        return FutureSessionCandidate(
            startMinutes: start,
            durationMinutes: duration == 0 ? group[0].durationMinutes : duration,
            gainPercent: gain,
            rawGainPercent: best.rawGainPercent,
            score: best.score,
            source: best.source,
            sourceLabel: labels,
            mergedCount: group.count,
            scenario: best.scenario,
            profile: best.profile
        )
    }
    .sorted { $0.startMinutes < $1.startMinutes }
}

private func generateCandidates(sessions: [UsageSession], events: [UsageChangeEvent], cutoff: Double, endMinutes: Double, parameters: ForecastParameters, mode: ForecastMode) -> [FutureSessionCandidate] {
    let half = parameters.recencyHalfLifeHours * 60
    let rhythmStrength = parameters.dailyRhythmStrengthPercent / 100
    let freqAccel = parameters.frequencyAccelerationPercent / 100
    let prototype = choosePrototype(sessions: sessions, cutoff: cutoff, parameters: parameters, mode: mode)
    let fallbackGainItems = sessions.map { session -> (value: Double, weight: Double) in
        let weight = recencyWeight(time: session.endMinutes, cutoff: cutoff, halfLifeMinutes: half) * (session.isIntense ? 1.2 : 1.0)
        return (session.gainPercent, weight)
    }
    let typicalGain = max(0.3, weightedQuantile(fallbackGainItems, q: mode.quantile).nonZeroOr(weightedAverage(fallbackGainItems)).nonZeroOr(1))
    let defaultProfile = cloneProfile(from: prototype, fallbackDuration: min(240, max(60, parameters.maxIdleGapInsideSessionMinutes)))

    var candidates: [FutureSessionCandidate] = []

    for session in sessions {
        let w = recencyWeight(time: session.endMinutes, cutoff: cutoff, halfLifeMinutes: half)
        let cycles = Int(ceil((endMinutes - session.startMinutes) / 1440)) + 1
        guard cycles >= 1 else { continue }
        for k in 1...cycles {
            let start = session.startMinutes + 1440 * Double(k)
            if start <= cutoff || start > endMinutes { continue }
            let score = max(0.05, rhythmStrength * (0.35 + 0.65 * w) * (session.isIntense ? 1.12 : 0.92))
            let sourceScale = max(0.08, score)
            candidates.append(FutureSessionCandidate(
                startMinutes: start,
                durationMinutes: session.durationMinutes,
                gainPercent: session.gainPercent * sourceScale,
                rawGainPercent: session.gainPercent,
                score: score,
                source: .daily,
                sourceLabel: candidateSourceLabel(.daily),
                mergedCount: 1,
                scenario: mode.name,
                profile: session.profile
            ))
        }
    }

    let starts = sessions.map(\.startMinutes).sorted()
    if starts.count >= 2 {
        var gapItems: [(value: Double, weight: Double)] = []
        for i in 1..<starts.count {
            let gap = starts[i] - starts[i - 1]
            if gap >= 20, gap <= 2400 {
                let weight = recencyWeight(time: starts[i], cutoff: cutoff, halfLifeMinutes: half)
                gapItems.append((gap, weight))
            }
        }
        var gap = weightedQuantile(gapItems, q: mode.gapQuantile).nonZeroOr(480)
        let accelMultiplier = exp(-freqAccel * mode.accelSensitivity)
        gap = clamp(gap * mode.gapFactor * accelMultiplier, 75, 1440)
        var start = (starts.last ?? cutoff) + gap
        var count = 0
        while start <= endMinutes, count < 18 {
            if start > cutoff {
                let score = max(0.02, (1 - rhythmStrength) * 0.72 * mode.intervalStrength)
                candidates.append(FutureSessionCandidate(
                    startMinutes: start,
                    durationMinutes: defaultProfile.duration,
                    gainPercent: typicalGain * score,
                    rawGainPercent: typicalGain,
                    score: score,
                    source: .interval,
                    sourceLabel: candidateSourceLabel(.interval),
                    mergedCount: 1,
                    scenario: mode.name,
                    profile: defaultProfile.profile
                ))
            }
            let recurrenceFactor = clamp(1 - freqAccel * 0.05, 0.72, 1.18)
            start += gap * pow(recurrenceFactor, Double(count + 1))
            count += 1
        }
    }

    if let lastEvent = events.last {
        let sinceLast = cutoff - lastEvent.offsetMinutes
        if sinceLast >= 0, sinceLast <= parameters.maxIdleGapInsideSessionMinutes {
            let score = mode.continuationStrength * (1 - sinceLast / max(1, parameters.maxIdleGapInsideSessionMinutes))
            if score > 0.01 {
                let delay = max(8, min(90, parameters.maxIdleGapInsideSessionMinutes * mode.continuationDelayFactor))
                candidates.append(FutureSessionCandidate(
                    startMinutes: cutoff + delay,
                    durationMinutes: defaultProfile.duration,
                    gainPercent: typicalGain * score,
                    rawGainPercent: typicalGain,
                    score: score,
                    source: .continuation,
                    sourceLabel: candidateSourceLabel(.continuation),
                    mergedCount: 1,
                    scenario: mode.name,
                    profile: defaultProfile.profile
                ))
            }
        }
    }

    return mergeCandidates(candidates, mergeGap: parameters.mergeNearbyFutureSessionCandidatesMinutes)
        .filter { $0.startMinutes <= endMinutes }
}

private func makeForecast(sessions: [UsageSession], events: [UsageChangeEvent], cutoff: Double, endMinutes: Double, currentY: Double, parameters: ForecastParameters, slopes: SlopeStats, mode: ForecastMode) -> ScenarioForecast {
    let step = max(5, parameters.forecastResolutionMinutes)
    let baseSlope = mode.name == .optimistic ? slopes.optimisticSlopePercentPerMinute : slopes.pessimisticSlopePercentPerMinute
    let slope = baseSlope * mode.linearScale
    let allCandidates = generateCandidates(sessions: sessions, events: events, cutoff: cutoff, endMinutes: endMinutes, parameters: parameters, mode: mode).map { candidate -> FutureSessionCandidate in
        var c = candidate
        c.gainPercent *= mode.activityScale
        return c
    }
    let returnedCandidates = parameters.includeCandidateDetails ? allCandidates : []

    let blend = clamp(parameters.linearSessionBlendPercent / 100, 0, 1)
    let idleSlope = parameters.backgroundIdleDriftPercentPerDay / 1440
    var points: [ForecastPoint] = []
    var lastY = currentY
    var t = cutoff
    while t <= endMinutes + 1e-6 {
        let dt = t - cutoff
        let linearDelta = slope * dt
        var sessionDelta = 0.0
        for candidate in allCandidates {
            let fraction = profileValue(candidate.profile, duration: candidate.durationMinutes, dt: t - candidate.startMinutes)
            sessionDelta += candidate.gainPercent * fraction
        }
        var y = currentY + blend * linearDelta + (1 - blend) * sessionDelta + idleSlope * dt
        if parameters.capForecastAt100Percent { y = min(100, y) }
        y = max(lastY, y)
        points.append(ForecastPoint(offsetMinutes: t, usedPercent: y))
        lastY = y
        t += step
    }
    if let last = points.last, last.offsetMinutes < endMinutes {
        points.append(ForecastPoint(offsetMinutes: endMinutes, usedPercent: last.usedPercent))
    }

    return ScenarioForecast(
        scenario: mode.name,
        points: points,
        candidates: returnedCandidates,
        slopePercentPerMinute: slope,
        finalUsedPercent: points.last?.usedPercent ?? currentY,
        crossing100Minutes: firstCrossing(points),
        sessionGainFinalPercent: allCandidates.reduce(0) { $0 + $1.gainPercent }
    )
}

private func makeLinearReference(cutoff: Double, endMinutes: Double, currentY: Double, parameters: ForecastParameters, slopes: SlopeStats) -> [ForecastPoint] {
    let step = max(5, parameters.forecastResolutionMinutes)
    var points: [ForecastPoint] = []
    var lastY = currentY
    var t = cutoff
    while t <= endMinutes + 1e-6 {
        var y = currentY + slopes.linearReferenceSlopePercentPerMinute * (t - cutoff)
        if parameters.capForecastAt100Percent { y = min(100, y) }
        y = max(lastY, y)
        points.append(ForecastPoint(offsetMinutes: t, usedPercent: y))
        lastY = y
        t += step
    }
    if let last = points.last, last.offsetMinutes < endMinutes {
        points.append(ForecastPoint(offsetMinutes: endMinutes, usedPercent: last.usedPercent))
    }
    return points
}

public func firstCrossing(_ points: [ForecastPoint], threshold: Double = 100) -> Double? {
    guard points.count >= 2 else { return nil }
    for i in 1..<points.count {
        let a = points[i - 1]
        let b = points[i]
        if a.usedPercent < threshold, b.usedPercent >= threshold {
            let u = (threshold - a.usedPercent) / max(1e-9, b.usedPercent - a.usedPercent)
            return a.offsetMinutes + (b.offsetMinutes - a.offsetMinutes) * u
        }
    }
    return nil
}

public func interpolatedUsagePercent(in points: [ForecastPoint], at offsetMinutes: Double) -> Double? {
    guard !points.isEmpty else { return nil }
    if offsetMinutes <= points[0].offsetMinutes { return points[0].usedPercent }
    for i in 1..<points.count {
        let a = points[i - 1]
        let b = points[i]
        if offsetMinutes <= b.offsetMinutes {
            let u = clamp((offsetMinutes - a.offsetMinutes) / max(1e-9, b.offsetMinutes - a.offsetMinutes), 0, 1)
            return a.usedPercent + (b.usedPercent - a.usedPercent) * u
        }
    }
    return points[points.count - 1].usedPercent
}

private func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in values where !seen.contains(value) {
        seen.insert(value)
        out.append(value)
    }
    return out
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    max(lower, min(upper, value))
}

private extension Double {
    func nonZeroOr(_ replacement: Double) -> Double {
        self == 0 ? replacement : self
    }
}
