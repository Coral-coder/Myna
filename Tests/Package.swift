// swift-tools-version:6.0
//
// Unit tests for Myna's platform-free logic. The sources are symlinks into the
// app target (Sources/MynaCore), so the code under test is exactly what ships;
// this package exists only so it can be tested with `swift test`, on macOS or
// Linux, without a simulator.
import PackageDescription

let package = Package(
    name: "MynaCore",
    platforms: [.macOS(.v14), .iOS(.v18)],
    targets: [
        .target(name: "MynaCore", path: "Sources/MynaCore"),
        .testTarget(name: "MynaCoreTests", dependencies: ["MynaCore"], path: "Tests/MynaCoreTests"),
    ],
    // The app builds in Swift 5 mode; test the code the same way.
    swiftLanguageModes: [.v5]
)
