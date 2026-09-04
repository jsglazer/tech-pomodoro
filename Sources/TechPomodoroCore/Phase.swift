import Foundation

/// The four interval kinds the multi-tier schedule cycles through:
/// `work` and `rest` alternate for the reps of a cycle, `longBreak` closes a cycle, and
/// `sessionRest` closes a session of cycles.
public enum Phase: String, Codable, Sendable, CaseIterable {
    case work
    case rest
    case longBreak
    case sessionRest

    /// Human label for the popover header and the analytics rows.
    public var title: String {
        switch self {
        case .work: return "Work"
        case .rest: return "Rest"
        case .longBreak: return "Long Break"
        case .sessionRest: return "Session Rest"
        }
    }
}
