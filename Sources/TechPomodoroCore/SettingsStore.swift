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
