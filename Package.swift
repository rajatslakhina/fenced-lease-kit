struct A {
    func b() {
        items.forEach { item in
            print(item)
        }
    }
}
// swift-tools-version: 6.0
import PackageDescription

// Only iOS and macOS are declared, because those are the only Apple platforms this
// repo's CI actually builds (the `macos-15` job builds every target and additionally
// compiles FencedLeaseUI for the iOS Simulator; a separate Linux job builds and tests
// the core, which `platforms:` does not describe). Declaring watchOS/tvOS/visionOS
// would be an untested claim -- and on watchOS `Int` is 32-bit, which this package's
// arithmetic guards account for by deriving ceilings from `Int.max` rather than
// hardcoding 64-bit literals.
let package = Package(
    name: "fenced-lease-kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "FencedLease", targets: ["FencedLease"]),
        .library(name: "FencedLeaseUI", targets: ["FencedLeaseUI"]),
    ],
    targets: [
        .target(
            name: "FencedLease",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FencedLeaseUI",
            dependencies: ["FencedLease"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FencedLeaseTests",
            dependencies: ["FencedLease"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
