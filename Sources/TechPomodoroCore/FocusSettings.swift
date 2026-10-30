import Foundation

/// The level at which drift is judged: moving to another task inside the same class counts as drift
/// at `.task`, but not at `.area`.
public enum DriftLevel: String, Codable, Sendable, CaseIterable {
    case task
    case area
}

/// Everything the focus tracker is configured by, nested inside `PomodoroSettings` under one key.
///
/// The defaults are the first-run configuration: classes under `Classes/{term}/{class}` are areas,
/// an assignment folder or the next folder down is a task, Anki/Zotero/PDF readers count toward
/// whatever you are working on, and every other app or site is a distraction.
public struct FocusSettings: Codable, Sendable, Equatable {
    /// Master switch. Off, the app never contacts ActivityWatch.
    public var enabled: Bool
    /// aw-server base URL.
    public var serverURL: String
    /// Continuous seconds off the anchor before the drift alert fires. `0` disables the alert.
    public var driftAlertSeconds: Int
    /// The anchor is the project with the most time in this many opening minutes of a Work interval.
    public var anchorLockMinutes: Int
    public var driftLevel: DriftLevel
    /// `#RRGGBB` the menu bar countdown turns while you are off the anchor.
    public var driftColorHex: String
    /// Folder globs, one per rule, first match wins: the matched folder is the note's area.
    public var areaRules: [String]
    /// Folder globs, first match wins: the matched folder is the note's task. Unmatched notes use
    /// their area as their task.
    public var taskRules: [String]
    /// App names whose time counts toward the anchor.
    public var onTaskApps: [String]
    /// Hosts (with an optional path prefix) whose browser time counts toward the anchor. A host also
    /// covers its subdomains.
    public var allowedSites: [String]
    /// App names that neither count nor drift: lock screen, auth prompts, this app.
    public var neutralApps: [String]

    public init(
        enabled: Bool = true,
        serverURL: String = "http://127.0.0.1:5600",
        driftAlertSeconds: Int = 30,
        anchorLockMinutes: Int = 5,
        driftLevel: DriftLevel = .task,
        driftColorHex: String = "#A855F7",
        areaRules: [String] = ["Classes/*/*"],
        taskRules: [String] = ["Classes/*/*/Assign/*", "Classes/*/*/*"],
        onTaskApps: [String] = ["Anki", "Zotero", "Preview", "Skim", "PDF Expert", "Adobe Acrobat", "Adobe Acrobat Reader"],
        allowedSites: [String] = ["library.gmu.edu", "schar.gmu.edu"],
        neutralApps: [String] = ["TechPomodoro", "loginwindow", "UserNotificationCenter", "coreautha", "ScreenSaverEngine"]
    ) {
        self.enabled = enabled
        self.serverURL = serverURL
        self.driftAlertSeconds = max(0, driftAlertSeconds)
        self.anchorLockMinutes = max(1, anchorLockMinutes)
        self.driftLevel = driftLevel
        self.driftColorHex = driftColorHex
        self.areaRules = areaRules
        self.taskRules = taskRules
        self.onTaskApps = onTaskApps
        self.allowedSites = allowedSites
        self.neutralApps = neutralApps
    }

    /// Tolerates a blob written before a key existed, like `PomodoroSettings` does.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FocusSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init(
            enabled: try value(.enabled, d.enabled),
            serverURL: try value(.serverURL, d.serverURL),
            driftAlertSeconds: try value(.driftAlertSeconds, d.driftAlertSeconds),
            anchorLockMinutes: try value(.anchorLockMinutes, d.anchorLockMinutes),
            driftLevel: try value(.driftLevel, d.driftLevel),
            driftColorHex: try value(.driftColorHex, d.driftColorHex),
            areaRules: try value(.areaRules, d.areaRules),
            taskRules: try value(.taskRules, d.taskRules),
            onTaskApps: try value(.onTaskApps, d.onTaskApps),
            allowedSites: try value(.allowedSites, d.allowedSites),
            neutralApps: try value(.neutralApps, d.neutralApps)
        )
    }
}
