import Foundation
import TokenUsageForecast

func format(_ value: Double, digits: Int = 1) -> String {
    String(format: "%.*f", digits, value)
}

func formatOffset(_ minutes: Double?) -> String {
    guard let minutes else { return "never" }
    let day = Int(minutes / 1440) + 1
    let rem = max(0, minutes.truncatingRemainder(dividingBy: 1440))
    let hour = Int(rem / 60)
    let minute = Int(rem.truncatingRemainder(dividingBy: 60))
    return String(format: "D%d %02d:%02d", day, hour, minute)
}

let args = CommandLine.arguments.dropFirst()
let path = args.first ?? "Examples/DemoQuotaData.json"
let url = URL(fileURLWithPath: path)
let snapshot = try UsageLimitSnapshot.load(from: url)
let result = try TokenUsageForecaster(parameters: .defaults).forecast(from: snapshot)

print("Token Usage Forecast")
print("cutoff:              \(formatOffset(result.cutoffMinutes))")
print("current:             \(format(result.currentUsedPercent))%")
print("linear final:        \(format(result.linearReferenceFinalPercent))%")
print("optimistic final:    \(format(result.optimistic.finalUsedPercent))%")
print("pessimistic final:   \(format(result.pessimistic.finalUsedPercent))%")
print("optimistic 100%:     \(formatOffset(result.optimistic.crossing100Minutes))")
print("pessimistic 100%:    \(formatOffset(result.pessimistic.crossing100Minutes))")
print("detected sessions:   \(result.sessions.count)")
print("optimistic clusters: \(result.optimistic.candidates.count)")
print("pessimistic clusters:\(result.pessimistic.candidates.count)")
