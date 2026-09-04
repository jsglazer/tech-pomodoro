import Foundation

/// The core's only source of "now".
///
/// Named `DateProvider` rather than `Clock` so it cannot be confused with the standard library's
/// `Clock` protocol. Every core call site takes the current date as a parameter; this type exists so
/// the shell can hand the same injected source to the reducer, the store, and the analytics view.
public struct DateProvider: Sendable {
    public let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    /// The real wall clock. Only the shell should use this.
    public static let system = DateProvider { Date() }

    /// A provider pinned to a fixed instant, for tests.
    public static func fixed(_ date: Date) -> DateProvider {
        DateProvider { date }
    }
}
