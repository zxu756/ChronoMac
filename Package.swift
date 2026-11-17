// swift-tools-version: 6.0
import Foundation
import PackageDescription

let cltTestingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSwiftSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingMacros)
    ? [.unsafeFlags(["-load-plugin-library", cltTestingMacros])]
    : []

let package = Package(
    name: "ChronoMac",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "ChronoMacCore", targets: ["ChronoMacCore"]),
        .executable(name: "ChronoMac", targets: ["ChronoMac"])
    ],
    targets: [
        .target(
            name: "ChronoMacCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ChronoMac",
            dependencies: ["ChronoMacCore"]
        ),
        .testTarget(
            name: "ChronoMacCoreTests",
            dependencies: ["ChronoMacCore"],
            exclude: ["Fixtures"],
            swiftSettings: testSwiftSettings
        )
    ],
    swiftLanguageModes: [.v5]
)
