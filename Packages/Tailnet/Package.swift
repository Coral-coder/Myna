// swift-tools-version: 5.9
import PackageDescription

// Tailscale inside Myna: Tailscale's own embeddable library (built for iPhone
// by .github/workflows/tailscale-ios.yml from github.com/tailscale/libtailscale,
// BSD-3-Clause) and a small Swift layer over the few calls Myna needs. When
// that workflow is run again, update the checksum below from the release.
let package = Package(
    name: "Tailnet",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Tailnet", targets: ["Tailnet"]),
    ],
    targets: [
        .binaryTarget(
            name: "libtailscale",
            url: "https://github.com/Coral-coder/Myna/releases/download/tailscale-ios/libtailscale.xcframework.zip",
            checksum: "8d5efc088da2b9a3b4f30e3f7ae4dbb82f4a9684a7c60cf92c3a9e0a0634f6ed"
        ),
        .target(
            name: "Tailnet",
            dependencies: ["libtailscale"],
            linkerSettings: [
                .linkedLibrary("resolv"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
