// swift-tools-version: 6.0
// tech-pomodoro — a customizable menu-bar Pomodoro timer for macOS.
// Targeted toolchain: Swift 6.3.3 / macOS 26.5 SDK. Deployment target: macOS 14.
import PackageDescription

let package = Package(
    name: "TechPomodoro",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Platform-agnostic domain logic. The whole headless test suite runs against this.
        .library(name: "TechPomodoroCore", targets: ["TechPomodoroCore"]),
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

        // MARK: - OS shell
        .executableTarget(
            name: "TechPomodoroApp",
            dependencies: ["TechPomodoroCore"],
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
        )
    ]
)
