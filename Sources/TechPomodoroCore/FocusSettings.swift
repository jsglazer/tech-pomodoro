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
    /// The document sensor: which apps' open documents are reported to ActivityWatch. Runs whether or
    /// not the timer is, and its paths feed the folder rules above.
    public var documents: DocumentSensorSettings
    /// How many `FocusMigrations` have been applied to these settings. Fresh settings start at the
    /// latest level; a blob written before migrations existed decodes as 0.
    public var migrationLevel: Int

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
        allowedSites: [String] = ["library.gmu.edu", "schar.gmu.edu", "windows.cloud.microsoft"],
        neutralApps: [String] = ["TechPomodoro", "loginwindow", "UserNotificationCenter", "coreautha", "ScreenSaverEngine"],
        documents: DocumentSensorSettings = DocumentSensorSettings(),
        migrationLevel: Int = FocusMigrations.latest
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
        self.documents = documents
        self.migrationLevel = migrationLevel
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
            neutralApps: try value(.neutralApps, d.neutralApps),
            documents: try value(.documents, d.documents),
            // Missing means "written before migrations existed": every migration still applies.
            migrationLevel: try value(.migrationLevel, 0)
        )
    }
}

/// One-time changes to settings people already have, applied in order and recorded in
/// `FocusSettings.migrationLevel` so each runs once. They only ever add; nothing the user set is
/// removed or overwritten.
public enum FocusMigrations {
    /// 1 — `windows.cloud.microsoft` (GMU's Mason Labs virtual desktop, used for Data - POGO 511)
    ///     counts as an on-task site.
    public static let latest = 1

    /// The migrated settings, or nil when they are already up to date.
    public static func migrate(_ settings: FocusSettings) -> FocusSettings? {
        guard settings.migrationLevel < latest else { return nil }
        var s = settings
        if s.migrationLevel < 1 {
            let site = "windows.cloud.microsoft"
            if !s.allowedSites.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(site) == .orderedSame }) {
                s.allowedSites.append(site)
            }
        }
        s.migrationLevel = latest
        return s
    }
}
