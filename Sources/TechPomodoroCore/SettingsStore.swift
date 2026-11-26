import Foundation

/// Where the settings blob lives.
public protocol SettingsStoring: Sendable {
    func load() -> PomodoroSettings
    func save(_ settings: PomodoroSettings)
}

/// Settings as one JSON blob under a single key, in an *injected* `UserDefaults` instance.
///
/// Core code never reaches for `UserDefaults.standard`; the app hands its instance in, and tests hand
/// in a throwaway suite.
/// `UserDefaults` is thread-safe but not `Sendable`, so the conformance is asserted here rather
/// than leaking the constraint into every caller.
public final class UserDefaultsSettingsStore: SettingsStoring, @unchecked Sendable {
    public static let defaultKey = "settings.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PomodoroSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(PomodoroSettings.self, from: data) else {
            return PomodoroSettings()
        }
        return decoded
    }

    public func save(_ settings: PomodoroSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}

/// A settings store backed by nothing, for tests and previews.
public final class MemorySettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: PomodoroSettings

    public init(settings: PomodoroSettings = PomodoroSettings()) {
        self.settings = settings
    }

    public func load() -> PomodoroSettings {
        lock.withLock { settings }
    }

    public func save(_ newSettings: PomodoroSettings) {
        lock.withLock { settings = newSettings }
    }
}

/// Settings edited continuously — a text field on every keystroke, a colour picker on every drag
/// tick — are shown at once but committed (saved, synced, acted on) only once editing ends. This
/// remembers the settings as they were before the first uncommitted edit, so the one commit compares
/// against the right baseline.
public struct SettingsDraft: Sendable, Equatable {
    public private(set) var baseline: PomodoroSettings?

    public init() {}

    public var isPending: Bool { baseline != nil }

    /// An edit is about to replace `current`; the first one since the last commit sets the baseline.
    public mutating func edit(replacing current: PomodoroSettings) {
        if baseline == nil { baseline = current }
    }

    /// Ends the draft. The baseline and `current` when they differ, so the caller commits the change
    /// once; nil when nothing was drafted, or the edits came back to where they started.
    public mutating func commit(current: PomodoroSettings) -> (old: PomodoroSettings, new: PomodoroSettings)? {
        guard let old = baseline else { return nil }
        baseline = nil
        return old == current ? nil : (old, current)
    }

    /// Drops the draft without committing it (the settings were replaced from elsewhere).
    public mutating func discard() {
        baseline = nil
    }
}
