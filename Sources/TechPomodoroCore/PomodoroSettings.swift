import Foundation

/// Which of the two menu bar representations the status item shows.
public enum MenuBarMode: String, Codable, Sendable, CaseIterable {
    case clockIcon
    case minutesRemaining
}

/// What the timer does when macOS goes to sleep.
public enum SleepBehavior: String, Codable, Sendable, CaseIterable {
    /// Keep counting against the wall clock; on wake, fast-forward to the phase the clock implies.
    case continueThroughSleep
    /// Pause on sleep and stay paused until the user resumes.
    case pauseOnSleep
    /// Freeze on sleep and pick up exactly where it left off on wake — same phase, same time
    /// remaining, running again without a click. Sleep time is neither counted nor logged.
    case resumeOnWake
}

/// Every user-configurable value, as one `Codable` value type.
///
/// The defaults here are the shipped first-run configuration: a 25/5 work-rest rep, three reps to a
/// cycle followed by a 15 minute long break, four cycles to a session followed by an hour of session
/// rest.
public struct PomodoroSettings: Codable, Sendable, Equatable {
    public var workMinutes: Int
    public var restMinutes: Int
    public var repsPerCycle: Int
    public var longBreakMinutes: Int
    public var cyclesPerSession: Int
    public var sessionRestMinutes: Int
    public var repeatSession: Bool

    public var menuBarMode: MenuBarMode
    /// Minutes remaining at or below which Work turns the warning colour. `0` disables the threshold.
    public var warningThresholdMinutes: Int
    /// Minutes remaining at or below which Work turns the alert colour. `0` disables the threshold.
    public var alertThresholdMinutes: Int
    /// Draw the menu bar title on a filled background instead of the bare bar.
    public var useCustomBackground: Bool
    /// Paint the menu bar countdown in `menuBarTextColorHex` instead of letting macOS colour it.
    public var useCustomTextColor: Bool
    /// `#RRGGBB`. Ignored unless `useCustomTextColor` is on, and never overrides a threshold colour.
    public var menuBarTextColorHex: String
    /// Colour the menu bar during the rest phases (Rest, Long Break, Session Rest) so a glance says
    /// which side of the schedule you are on.
    public var useRestColor: Bool
    /// `#RRGGBB` for the rest phases. Ignored unless `useRestColor` is on.
    public var restColorHex: String

    public var dingEnabled: Bool
    /// How many times the ding repeats at a boundary.
    public var dingRepeatCount: Int
    public var flashEnabled: Bool
    /// How many times the menu bar icon blinks at a boundary.
    public var flashRepeatCount: Int
    /// Shows a modal alert dialog at every phase boundary, in addition to the ding and the flash.
    public var popupEnabled: Bool
    /// Seconds before an unanswered alert dialog dismisses itself. `0` leaves it up until clicked.
    public var popupDismissSeconds: Int
    public var soundName: String
    public var launchAtLogin: Bool
    public var sleepBehavior: SleepBehavior
    /// Project tracking against ActivityWatch during Work intervals.
    public var focus: FocusSettings
    /// Sync settings and history through the user's private iCloud (CloudKit) database. Per device:
    /// it is never itself synced, so turning it off on one device leaves the others alone.
    public var cloudSyncEnabled: Bool
    /// Mac: push this Mac's timer to the iPhone's Live Activity. iPhone: show a Mac's timer in place
    /// of its own while one is active. Per device, never synced.
    public var mirrorEnabled: Bool
    /// The classes the paper tag offers, as class folder names exactly — the vault totals match on
    /// them. Synced.
    public var paperClasses: [String]
    /// How many `PaperMigrations` have been applied. Synced, so each runs once across devices.
    public var paperMigrationLevel: Int
    /// Mac: publish paper sittings to ActivityWatch and the vault file. Per device, never synced:
    /// only one Mac may publish, because aw-sync copies buckets between Macs.
    public var paperPublishEnabled: Bool
    /// Mac: the app-owned vault file the paper sittings are written to. Per device.
    public var paperLogPath: String

    public static let defaultPaperLogPath = "/Users/josh/VaultSchar/Classes/2026-B/Paper Log.json"

    public init(
        workMinutes: Int = 25,
        restMinutes: Int = 5,
        repsPerCycle: Int = 3,
        longBreakMinutes: Int = 15,
        cyclesPerSession: Int = 4,
        sessionRestMinutes: Int = 60,
        repeatSession: Bool = false,
        menuBarMode: MenuBarMode = .minutesRemaining,
        warningThresholdMinutes: Int = 5,
        alertThresholdMinutes: Int = 3,
        useCustomBackground: Bool = false,
        useCustomTextColor: Bool = false,
        menuBarTextColorHex: String = "#22D3EE",
        useRestColor: Bool = true,
        restColorHex: String = "#22C55E",
        dingEnabled: Bool = true,
        dingRepeatCount: Int = 1,
        flashEnabled: Bool = true,
        flashRepeatCount: Int = 3,
        popupEnabled: Bool = false,
        popupDismissSeconds: Int = 15,
        soundName: String = "Glass",
        launchAtLogin: Bool = false,
        sleepBehavior: SleepBehavior = .resumeOnWake,
        focus: FocusSettings = FocusSettings(),
        cloudSyncEnabled: Bool = true,
        mirrorEnabled: Bool = true,
        paperClasses: [String] = PaperDefaults.classes,
        paperMigrationLevel: Int = PaperMigrations.latest,
        paperPublishEnabled: Bool = false,
        paperLogPath: String = PomodoroSettings.defaultPaperLogPath
    ) {
        self.workMinutes = workMinutes
        self.restMinutes = restMinutes
        self.repsPerCycle = repsPerCycle
        self.longBreakMinutes = longBreakMinutes
        self.cyclesPerSession = cyclesPerSession
        self.sessionRestMinutes = sessionRestMinutes
        self.repeatSession = repeatSession
        self.menuBarMode = menuBarMode
        self.warningThresholdMinutes = warningThresholdMinutes
        self.alertThresholdMinutes = alertThresholdMinutes
        self.useCustomBackground = useCustomBackground
        self.useCustomTextColor = useCustomTextColor
        self.menuBarTextColorHex = menuBarTextColorHex
        self.useRestColor = useRestColor
        self.restColorHex = restColorHex
        self.dingEnabled = dingEnabled
        self.dingRepeatCount = max(1, dingRepeatCount)
        self.flashEnabled = flashEnabled
        self.flashRepeatCount = max(1, flashRepeatCount)
        self.popupEnabled = popupEnabled
        self.popupDismissSeconds = max(0, popupDismissSeconds)
        self.soundName = soundName
        self.launchAtLogin = launchAtLogin
        self.sleepBehavior = sleepBehavior
        self.focus = focus
        self.cloudSyncEnabled = cloudSyncEnabled
        self.mirrorEnabled = mirrorEnabled
        self.paperClasses = paperClasses
        self.paperMigrationLevel = paperMigrationLevel
        self.paperPublishEnabled = paperPublishEnabled
        self.paperLogPath = paperLogPath
    }

    /// A phase's configured length. Never zero: a phase of no length would let the reducer's
    /// fast-forward loop spin without advancing the clock.
    public func duration(of phase: Phase) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .work: minutes = workMinutes
        case .rest: minutes = restMinutes
        case .longBreak: minutes = longBreakMinutes
        case .sessionRest: minutes = sessionRestMinutes
        }
        return TimeInterval(max(1, minutes) * 60)
    }

    /// Decoding tolerates a settings blob written by an older build: any key the stored JSON is
    /// missing falls back to its shipped default rather than failing the whole decode.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init(
            workMinutes: try value(.workMinutes, d.workMinutes),
            restMinutes: try value(.restMinutes, d.restMinutes),
            repsPerCycle: try value(.repsPerCycle, d.repsPerCycle),
            longBreakMinutes: try value(.longBreakMinutes, d.longBreakMinutes),
            cyclesPerSession: try value(.cyclesPerSession, d.cyclesPerSession),
            sessionRestMinutes: try value(.sessionRestMinutes, d.sessionRestMinutes),
            repeatSession: try value(.repeatSession, d.repeatSession),
            menuBarMode: try value(.menuBarMode, d.menuBarMode),
            warningThresholdMinutes: try value(.warningThresholdMinutes, d.warningThresholdMinutes),
            alertThresholdMinutes: try value(.alertThresholdMinutes, d.alertThresholdMinutes),
            useCustomBackground: try value(.useCustomBackground, d.useCustomBackground),
            useCustomTextColor: try value(.useCustomTextColor, d.useCustomTextColor),
            menuBarTextColorHex: try value(.menuBarTextColorHex, d.menuBarTextColorHex),
            useRestColor: try value(.useRestColor, d.useRestColor),
            restColorHex: try value(.restColorHex, d.restColorHex),
            dingEnabled: try value(.dingEnabled, d.dingEnabled),
            dingRepeatCount: try value(.dingRepeatCount, d.dingRepeatCount),
            flashEnabled: try value(.flashEnabled, d.flashEnabled),
            flashRepeatCount: try value(.flashRepeatCount, d.flashRepeatCount),
            popupEnabled: try value(.popupEnabled, d.popupEnabled),
            popupDismissSeconds: try value(.popupDismissSeconds, d.popupDismissSeconds),
            soundName: try value(.soundName, d.soundName),
            launchAtLogin: try value(.launchAtLogin, d.launchAtLogin),
            sleepBehavior: try value(.sleepBehavior, d.sleepBehavior),
            focus: try value(.focus, d.focus),
            cloudSyncEnabled: try value(.cloudSyncEnabled, d.cloudSyncEnabled),
            mirrorEnabled: try value(.mirrorEnabled, d.mirrorEnabled),
            // Missing means "written before paper time existed": the migration fills the list.
            paperClasses: try value(.paperClasses, []),
            paperMigrationLevel: try value(.paperMigrationLevel, 0),
            paperPublishEnabled: try value(.paperPublishEnabled, d.paperPublishEnabled),
            paperLogPath: try value(.paperLogPath, d.paperLogPath)
        )
    }
}

/// One-time changes to the paper settings, tracked by `PomodoroSettings.paperMigrationLevel`.
public enum PaperMigrations {
    /// 1 — the class list starts as the 2026-B class folders.
    public static let latest = 1

    /// The migrated settings, or nil when they are already up to date. Only ever adds.
    public static func migrate(_ settings: PomodoroSettings) -> PomodoroSettings? {
        guard settings.paperMigrationLevel < latest else { return nil }
        var s = settings
        if s.paperMigrationLevel < 1 {
            for name in PaperDefaults.classes where !s.paperClasses.contains(name) {
                s.paperClasses.append(name)
            }
        }
        s.paperMigrationLevel = latest
        return s
    }
}

/// Every pending one-time settings migration, focus and paper alike.
public enum SettingsMigrations {
    /// The migrated settings, or nil when nothing was pending.
    public static func migrate(_ settings: PomodoroSettings) -> PomodoroSettings? {
        var s = settings
        var changed = false
        if let focus = FocusMigrations.migrate(s.focus) {
            s.focus = focus
            changed = true
        }
        if let paper = PaperMigrations.migrate(s) {
            s = paper
            changed = true
        }
        return changed ? s : nil
    }
}
