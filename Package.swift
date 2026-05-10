// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TokenUsageForecast",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "TokenUsageForecast",
            targets: ["TokenUsageForecast"]
        ),
        .executable(
            name: "token-usage-forecast-demo",
            targets: ["TokenUsageForecastDemo"]
        )
    ],
    targets: [
        .target(
            name: "TokenUsageForecast"
        ),
        .executableTarget(
            name: "TokenUsageForecastDemo",
            dependencies: ["TokenUsageForecast"]
        ),
        .testTarget(
            name: "TokenUsageForecastTests",
            dependencies: ["TokenUsageForecast"],
            resources: [
                .copy("Resources/DemoQuotaData.json")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
