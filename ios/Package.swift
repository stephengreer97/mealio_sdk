// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MealioSDK",
    platforms: [
        .iOS(.v15),
        // macOS is listed only so `swift test` can run the platform-neutral
        // tests (protocol, signatures, allowlist, runner, client) on a Mac
        // without a simulator. The WebView host, MealioCart and the SwiftUI
        // sheet are iOS only (#if canImport(UIKit)).
        .macOS(.v12),
    ],
    products: [
        .library(name: "MealioSDK", targets: ["MealioSDK"]),
    ],
    targets: [
        .target(
            name: "MealioSDK",
            path: "Sources/MealioSDK"
        ),
        .testTarget(
            name: "MealioSDKTests",
            dependencies: ["MealioSDK"],
            path: "Tests/MealioSDKTests",
            resources: [
                // test-vectors.json, strings.json and fake-script.json are
                // copies of the files in ../protocol.
                // guard-script.js and bridge-shim.js are the exact text of
                // GUARD_SCRIPT and BRIDGE_SHIM generated from the TS reference.
                .copy("Resources/test-vectors.json"),
                .copy("Resources/strings.json"),
                .copy("Resources/fake-script.json"),
                .copy("Resources/guard-script.js"),
                .copy("Resources/bridge-shim.js"),
            ]
        ),
    ]
)
