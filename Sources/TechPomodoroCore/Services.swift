import Foundation

/// Plays the completion ding. Implemented with `NSSound` in the shell, mocked in tests.
public protocol SoundPlaying: Sendable {
    /// Plays `name` `times` times in succession. A new request replaces any repeats still pending.
    func play(named name: String, times: Int)
}

extension SoundPlaying {
    public func play(named name: String) {
        play(named: name, times: 1)
    }
}

/// Offers the names of the system sounds that can actually be played on this machine.
public protocol SoundCatalogProviding: Sendable {
    var availableSoundNames: [String] { get }
}

/// Draws the abstract menu bar appearance and runs the completion flash. Main-actor isolated
/// because every implementation of it drives a status item.
@MainActor
public protocol MenuBarPresenting: AnyObject {
    func apply(_ presentation: MenuBarPresentation)
    /// Blinks the item `times` times. A new request replaces a flash still in flight.
    func flash(times: Int)
}

/// Launch-at-login, behind a protocol because `SMAppService` only behaves inside a registered bundle.
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    /// Returns the state actually achieved, plus a warning when the request could not be honoured —
    /// an unregistered development build must degrade to a no-op, never throw or crash.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> LoginItemResult
}

public struct LoginItemResult: Sendable, Equatable {
    public let isEnabled: Bool
    public let warning: String?

    public init(isEnabled: Bool, warning: String? = nil) {
        self.isEnabled = isEnabled
        self.warning = warning
    }
}

/// A login-item control that records what was asked of it and honours nothing.
public final class NoOpLoginItemController: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    public init() {}

    public var isEnabled: Bool { lock.withLock { enabled } }

    @discardableResult
    public func setEnabled(_ newValue: Bool) -> LoginItemResult {
        lock.withLock { enabled = newValue }
        return LoginItemResult(isEnabled: newValue, warning: nil)
    }
}
