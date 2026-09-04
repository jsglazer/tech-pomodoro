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

    public var dingEnabled: Bool
    public var flashEnabled: Bool
    public var soundName: String
    public var launchAtLogin: Bool
    public var sleepBehavior: SleepBehavior

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
        dingEnabled: Bool = true,
        flashEnabled: Bool = true,
        soundName: String = "Glass",
        launchAtLogin: Bool = false,
        sleepBehavior: SleepBehavior = .continueThroughSleep
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
        self.dingEnabled = dingEnabled
        self.flashEnabled = flashEnabled
        self.soundName = soundName
        self.launchAtLogin = launchAtLogin
        self.sleepBehavior = sleepBehavior
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
            dingEnabled: try value(.dingEnabled, d.dingEnabled),
            flashEnabled: try value(.flashEnabled, d.flashEnabled),
            soundName: try value(.soundName, d.soundName),
            launchAtLogin: try value(.launchAtLogin, d.launchAtLogin),
            sleepBehavior: try value(.sleepBehavior, d.sleepBehavior)
        )
    }
}
