# TokenUsageForecast

A Swift 6 package that forecasts the remainder of a 7-day token quota window from observed usage samples. It ports the interactive HTML model into a reusable Swift library: linear extrapolation is blended with detected usage sessions, repeated daily rhythm, inter-session cadence, frequency acceleration, and background drift.

The model returns three curves:

- `linearReference`: baseline period-rate extrapolation.
- `optimistic`: lower-risk continuation using a milder linear scale and lower session quantiles.
- `pessimistic`: higher-usage continuation using stronger recent/session weighting.

Forecasts are not capped at 100% by default.

## Installation

Add the package in Xcode or in `Package.swift`:

```swift
.package(url: "https://github.com/pardeike/TokenUsageForecast.git", from: "1.0.0")
```

Then depend on:

```swift
.product(name: "TokenUsageForecast", package: "TokenUsageForecast")
```

## Quick use

```swift
import Foundation
import TokenUsageForecast

let snapshot = try UsageLimitSnapshot.load(from: URL(fileURLWithPath: "DemoQuotaData.json"))
var params = ForecastParameters.defaults
params.capForecastAt100Percent = false

let result = try TokenUsageForecaster(parameters: params).forecast(from: snapshot)

print(result.currentUsedPercent)
print(result.optimistic.finalUsedPercent)
print(result.pessimistic.finalUsedPercent)
print(result.sessions.count)
```

## Screenshot-tuned default parameters

`ForecastParameters.defaults` mirrors the values from the tuned HTML screenshot:

| Parameter | Default |
|---|---:|
| `maxIdleGapInsideSessionMinutes` | `25` |
| `mergeNearbyFutureSessionCandidatesMinutes` | `105` |
| `burstThresholdPercentPerHour` | `2.75` |
| `minimumGainForIntenseClusterPercent` | `1` |
| `recencyHalfLifeHours` | `3` |
| `linearSessionBlendPercent` | `14` |
| `dailyRhythmStrengthPercent` | `20` |
| `frequencyAccelerationPercent` | `41` |
| `backgroundIdleDriftPercentPerDay` | `11` |
| `forecastResolutionMinutes` | `70` |
| `optimisticActivityScale` | `1.30` |
| `pessimisticActivityScale` | `1.50` |
| `includeHeldoutSamples` | `true` |
| `includeCandidateDetails` | `true` |
| `capForecastAt100Percent` | `false` |
| `cutoffMinutes` | `nil` / latest observed elapsed minute |

`ForecastParameters.htmlPrototypeDefaults` is also included for comparing against the initial HTML prototype.

## Input shape

The decoder accepts the same JSON shape as the original demo data:

```json
{
  "weeklyWindowMinutes": 10080,
  "elapsedWindowMinutes": 7662,
  "weeklyUsedPercent": 72,
  "samples": [
    { "offsetMinutes": 1218, "offsetSeconds": 73112, "weeklyUsedPercent": 28 }
  ]
}
```

`offsetMinutes` or `offsetSeconds` may be present. Percent values are `Double`s and are allowed to exceed 100 in forecasts.

## Demo CLI

From the package root:

```bash
swift run token-usage-forecast-demo Examples/DemoQuotaData.json
```

The command prints current usage, final linear/optimistic/pessimistic estimates, predicted 100% crossings, and detected session counts.

## Notes on the algorithm

The forecaster deliberately uses a pragmatic heuristic model rather than a statistical black box:

1. Token increases are compressed into change events.
2. Change events are grouped into sessions using `maxIdleGapInsideSessionMinutes`.
3. Sessions are scored by gain, duration, intensity, and recency.
4. Future candidates are generated from same-time-next-day echoes, recent inter-session gaps, and active-session continuation.
5. Candidate starts are merged using `mergeNearbyFutureSessionCandidatesMinutes`.
6. Forecasted usage is a monotonic blend of linear slope, session candidate profiles, and background drift.

This makes the output explainable and easy to tune from UI sliders or app settings.
