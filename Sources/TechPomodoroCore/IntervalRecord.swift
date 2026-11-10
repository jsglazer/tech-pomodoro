import Foundation

/// One logged event in the analytics history.
public struct IntervalRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A work interval, complete or partial. Carries the seconds actually worked.
        case work
        /// A cycle that reached its Long Break. Carries no elapsed time.
        case cycleCompleted
        /// A session that reached its Session Rest. Carries no elapsed time.
        case sessionCompleted
    }

    public let id: UUID
    public let kind: Kind
    public let startedAt: Date
    public let elapsedSeconds: Int
    /// `false` for a work interval ended early by Stop, by Skip, or by a paper tag change part-way.
    public let completed: Bool
    /// What the interval was spent on, when focus tracking saw it. Work records only; absent from
    /// history written before focus tracking existed.
    public var focus: FocusSummary?
    /// Set when the Work ran under a paper tag. Work records only; the key is absent when nil, so
    /// older history and older app versions still decode.
    public var paper: PaperSitting?
    /// True for a past sitting logged by hand: it adds paper time, never reps or work time.
    public var manual: Bool?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        startedAt: Date,
        elapsedSeconds: Int,
        completed: Bool,
        focus: FocusSummary? = nil,
        paper: PaperSitting? = nil,
        manual: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startedAt = startedAt
        self.elapsedSeconds = elapsedSeconds
        self.completed = completed
        self.focus = focus
        self.paper = paper
        self.manual = manual
    }

    public var isManual: Bool { manual == true }
}
