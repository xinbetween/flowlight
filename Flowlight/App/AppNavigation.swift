import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case live, agents, reports, alerts, rules, ask, inspect, devices, coverage, capture
    var id: String { rawValue }
    /// The part of the documentation that explains this screen.
    ///
    /// The docs are laid out in the sidebar's own groups — Traffic, Investigate, Control, Sources — so help
    /// asked for from a screen lands on the section about that screen rather than at the top of a long page
    /// someone then has to search.
    nonisolated var helpAnchor: String {
        switch self {
        case .live: return "views"
        case .agents: return "agents"
        case .reports: return "worth-a-look"
        case .alerts: return "alerts"
        case .rules: return "rules"
        case .ask: return "ask"
        case .inspect: return "inspection"
        case .devices: return "devices"
        case .coverage: return "coverage"
        case .capture: return "capture"
        }
    }

    /// The English name, for the places that aren't the interface: the feature guide the Ask panel reads, whose
    /// search index is matched against English words, and anything else the model rather than a person reads.
    nonisolated var englishTitle: String {
        switch self {
        case .live: return "Live"
        case .agents: return "AI Agents"
        case .reports: return "Reports"
        case .alerts: return "Alerts"
        case .rules: return "Rules"
        case .ask: return "Ask"
        case .inspect: return "Inspect"
        case .devices: return "Devices"
        case .coverage: return "Coverage"
        case .capture: return "Capture"
        }
    }

    @MainActor var title: String {
        switch self {
        case .live: return L("Live")
        case .agents: return L("AI Agents")
        case .reports: return L("Reports")
        case .alerts: return L("Alerts")
        case .rules: return L("Rules")
        case .ask: return L("Ask")
        case .devices: return L("Devices")
        case .coverage: return L("Coverage")
        case .inspect: return L("Inspect")
        case .capture: return L("Capture")
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
        case .coverage: return "circle.dashed.inset.filled"
        case .inspect: return "lock.open.display"
        case .capture: return "antenna.radiowaves.left.and.right"
        }
    }
    /// ⌘1…⌘9 and then ⌘0, the way every browser numbers its tabs. Nil past the tenth: there is no eleventh
    /// digit, and the arithmetic that assumed there was turned `10` into a `Character` and trapped the moment
    /// a tenth screen was added.
    var shortcut: KeyEquivalent? {
        guard let index = Self.allCases.firstIndex(of: self), index < 10 else { return nil }
        return KeyEquivalent(Character("\(index == 9 ? 0 : index + 1)"))
    }

    var section: SidebarSection {
        switch self {
        case .live, .agents, .reports, .alerts: return .traffic
        case .ask, .inspect: return .investigate
        case .rules: return .control
        case .devices, .coverage, .capture: return .sources
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

    @MainActor var title: String {
        switch self {
        case .traffic: return L("Traffic")
        case .investigate: return L("Investigate")
        case .control: return L("Control")
        case .sources: return L("Sources")
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
    @Published var selection: SidebarItem = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "FLScreen") ?? "") ?? .live
    @Published var reportRequest: ReportRequest?
    @Published var inspectRequest: InspectRequest?
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

    /// Open Inspect already looking at one app, host or address.
    ///
    /// Inspect searches one field across hosts, paths, app names, tools and bodies, so "show me this row's
    /// traffic" is that field pre-filled rather than a second filtering mechanism. It also means the search
    /// stays visible and editable: someone who arrives here can widen or narrow it without going back.
    func showInspect(search: String) {
        inspectRequest = InspectRequest(search: search)
        selection = .inspect
    }
}

/// A request from another screen to open Inspect scoped to something.
struct InspectRequest: Equatable {
    var search: String
    var id = UUID()
}
