// swift-tools-version: 6.0
// tech-pomodoro — a customizable menu-bar Pomodoro timer for macOS, with an iOS companion app.
// Targeted toolchain: Swift 6.3.3 / macOS 26.5 SDK. Deployment targets: macOS 14, iOS 18.
import PackageDescription

let package = Package(
    name: "TechPomodoro",
    platforms: [
        .macOS(.v14),
        // The iOS app (project.yml) links only TechPomodoroCore; the AppKit shell below is never built for iOS.
        .iOS(.v18)
    ],
    products: [
        // Platform-agnostic domain logic. The whole headless test suite runs against this.
        .library(name: "TechPomodoroCore", targets: ["TechPomodoroCore"]),
        // CloudKit sync of settings and history, shared by the Mac and iOS apps.
        .library(name: "TechPomodoroSync", targets: ["TechPomodoroSync"]),
        // APNs signing, Keychain storage and the HTTP client the Mac pushes Live Activities with.
        .library(name: "TechPomodoroAPNs", targets: ["TechPomodoroAPNs"]),
        // The OS shell (AppKit status item + SwiftUI popover). Not part of the headless gate.
        .executable(name: "TechPomodoroApp", targets: ["TechPomodoroApp"])
    ],
    targets: [
        // MARK: - Pure core (no AppKit / SwiftUI, no wall-clock reads, no hardcoded paths)
        .target(
            name: "TechPomodoroCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - iCloud sync (CloudKit; every merge rule it applies lives in the core)
        .target(
            name: "TechPomodoroSync",
            dependencies: ["TechPomodoroCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - APNs (JWT signing, Keychain, HTTP) — a library so the tests can reach it
        .target(
            name: "TechPomodoroAPNs",
            dependencies: ["TechPomodoroCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - OS shell
        .executableTarget(
            name: "TechPomodoroApp",
            dependencies: ["TechPomodoroCore", "TechPomodoroSync", "TechPomodoroAPNs"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),

        // MARK: - Deterministic headless tests (the machine-checkable gate)
        .testTarget(
            name: "TechPomodoroCoreTests",
            dependencies: ["TechPomodoroCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TechPomodoroSyncTests",
            dependencies: ["TechPomodoroCore", "TechPomodoroSync"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TechPomodoroAPNsTests",
            dependencies: ["TechPomodoroCore", "TechPomodoroAPNs"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
