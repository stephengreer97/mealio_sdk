// swift-tools-version:5.9
// The Swift Package Manager entry point for the iOS SDK:
//
//     .package(url: "https://github.com/stephengreer97/mealio_sdk.git", from: "0.4.0")
//
// SwiftPM reads only the manifest at the repository root, so this one points
// into ios/. ios/Package.swift is the same library plus its tests, for CI.
import PackageDescription

let package = Package(
    name: "MealioSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "MealioSDK", targets: ["MealioSDK"]),
    ],
    targets: [
        .target(
            name: "MealioSDK",
            path: "ios/Sources/MealioSDK"
        ),
    ]
)
