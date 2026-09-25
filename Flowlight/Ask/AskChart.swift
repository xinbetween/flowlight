import Foundation

/// A chart an answer can carry.
///
/// Some questions have a shape rather than a number. "When did it happen" is a line, "who sent the most" is a set
/// of bars, "how is it split" is a pie. The model doesn't draw anything — Flowlight builds the chart from the same
/// rows the query returned, so what is drawn and what is said come from one source and cannot disagree.
struct AskChart: Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case line, bar, pie, none

        /// What a model may write. `none` is here so a question that would look silly as a chart can say so.
        static var names: [String] { allCases.map(\.rawValue) }
    }

    enum Unit: String, Equatable, Sendable {
        /// Formatted with ByteFormat — the axis is bytes, not a bare number in the millions.
        case bytes
        case count
    }

    struct Point: Equatable, Sendable, Identifiable {
        var id = UUID()
        /// The category for a bar or a slice; for a line it labels the series.
        var label: String
        /// Set for time series only.
        var date: Date?
        var value: Double
        /// A second value drawn against the first — received beside sent.
        var secondary: Double?
    }

    var kind: Kind
    var title: String
    var unit: Unit
    var points: [Point]
    /// What the two values mean, when there are two.
    var primaryName = "Sent"
    var secondaryName = "Received"

    var isEmpty: Bool { points.isEmpty || kind == .none }

    /// A chart of more than a handful of slices is a colour-matching exercise, not a chart. Bars tolerate more.
    static func trimmed(_ points: [Point], kind: Kind) -> [Point] {
        let limit = kind == .pie ? 6 : 12
        guard points.count > limit else { return points }
        let top = Array(points.prefix(limit - 1))
        let rest = points.dropFirst(limit - 1)
        let other = Point(label: "Other (\(rest.count))", value: rest.reduce(0) { $0 + $1.value },
                          secondary: rest.contains { $0.secondary != nil }
                              ? rest.reduce(0) { $0 + ($1.secondary ?? 0) } : nil)
        return top + [other]
    }

    /// What the model asked for, or the shape that suits the query when it didn't say.
    static func kind(requested: String?, natural: Kind) -> Kind {
        guard let requested = requested?.trimmingCharacters(in: .whitespaces).lowercased(), !requested.isEmpty,
              let asked = Kind(rawValue: requested) else { return natural }
        return asked
    }
}
