import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case live, agents, reports, alerts, rules, ask, inspect, devices, capture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live"
        case .agents: return "AI Agents"
        case .reports: return "Reports"
        case .alerts: return "Alerts"
        case .rules: return "Rules"
        case .ask: return "Ask"
        case .devices: return "Devices"
        case .inspect: return "Inspect"
        case .capture: return "Capture"
        }
    }
    var icon: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .agents: return "sparkles"
        case .reports: return "chart.bar.xaxis"
        case .alerts: return "exclamationmark.triangle"
        case .rules: return "hand.raised"
        case .ask: return "text.bubble"
        case .devices: return "dot.radiowaves.left.and.right"
        case .inspect: return "lock.open.display"
        case .capture: return "antenna.radiowaves.left.and.right"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }

    var section: SidebarSection {
        switch self {
        case .live, .agents, .reports, .alerts: return .traffic
        case .ask, .inspect: return .investigate
        case .rules: return .control
        case .devices, .capture: return .sources
        }
    }
}

/// The sidebar in groups rather than one column of nine.
///
/// Nine is where a flat list stops being scannable: the eye has to read every label to find the one it wants.
/// The grouping is by what someone is trying to do — see what happened, look closer at it, refuse something, or
/// change where the data comes from — rather than by which part of the app the code lives in.
enum SidebarSection: String, CaseIterable, Identifiable {
    case traffic, investigate, control, sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .traffic: return "Traffic"
        case .investigate: return "Investigate"
        case .control: return "Control"
        case .sources: return "Sources"
        }
    }

    var items: [SidebarItem] { SidebarItem.allCases.filter { $0.section == self } }
}

/// A rule the user started writing somewhere else — a table row, an alert — waiting for the Rules screen to open
/// its editor. The rule travels rather than its ingredients, so every "Block this" writes the same object.
struct RuleRequest: Equatable {
    var rule: Rule
    var id = UUID()
}

/// A request from another screen to open Reports with a given scope.
struct ReportRequest: Equatable {
    var filter: TrafficFilter
    var granularity: Granularity?
    var end: Date?
    var id = UUID()
}

/// Shared navigation state so screens can link to each other (Live/Alerts → Reports).
@MainActor
final class AppNavigation: ObservableObject {
    @Published var selection: SidebarItem = .live
    @Published var reportRequest: ReportRequest?
    @Published var ruleRequest: RuleRequest?

    /// Opens the Rules screen with this rule in the editor, unsaved. Writing a rule from a table row should land
    /// somewhere it can be read back and changed, not quietly take effect out of sight.
    func writeRule(_ rule: Rule) {
        ruleRequest = RuleRequest(rule: rule)
        selection = .rules
    }

    func showReport(filter: TrafficFilter, granularity: Granularity? = nil, end: Date? = nil) {
        reportRequest = ReportRequest(filter: filter, granularity: granularity, end: end)
        selection = .reports
    }
}
