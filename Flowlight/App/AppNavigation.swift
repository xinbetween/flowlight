import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case live, agents, reports, alerts, rules, ask, inspect, devices, coverage, capture, visualize
    var id: String { rawValue }

    static var availableCases: [SidebarItem] {
        #if APP_STORE
        allCases.filter { $0 != .inspect }
        #else
        allCases
        #endif
    }

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
        case .visualize: return "visualize"
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
        case .reports: return "History"
        case .visualize: return "Connections"
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
        case .reports: return L("History")
        case .visualize: return L("Connections")
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
        case .visualize: return "point.3.connected.trianglepath.dotted"
        case .alerts: return "exclamationmark.triangle"
        case .rules: return "hand.raised"
        case .ask: return "text.bubble"
        case .devices: return "dot.radiowaves.left.and.right"
        case .coverage: return "circle.dashed.inset.filled"
        case .inspect: return "lock.open.display"
        case .capture: return "antenna.radiowaves.left.and.right"
        }
    }
    /// The exact visual order of the sidebar. Enum declaration order is an implementation detail and used to
    /// make Connections appear fourth while Alerts still claimed ⌘4. Commands and documentation both promise
    /// positional shortcuts, so derive them from the grouped navigation people can actually see.
    static var sidebarOrder: [SidebarItem] {
        SidebarSection.allCases.flatMap(\.items)
    }

    /// ⌘1…⌘9 and then ⌘0, the way every browser numbers its tabs. Nil past the tenth: there is no eleventh
    /// digit, and the arithmetic that assumed there was turned `10` into a `Character` and trapped the moment
    /// a tenth screen was added.
    var shortcut: KeyEquivalent? {
        guard let index = Self.sidebarOrder.firstIndex(of: self), index < 10 else { return nil }
        return KeyEquivalent(Character("\(index == 9 ? 0 : index + 1)"))
    }

    var section: SidebarSection {
        switch self {
        case .live, .agents, .reports, .visualize, .alerts: return .traffic
        case .ask, .inspect: return .investigate
        case .rules: return .control
        case .devices, .coverage, .capture: return .sources
        }
    }

    /// Whether the destination can honestly say that the complete active Focus scope is filtering its content.
    /// Alerts can apply app targets but have no destination field, while operational/configuration screens and Ask
    /// do not apply traffic scope at all. They still show the persistent Focus notice, using neutral wording.
    func fullyAppliesFocus(_ scope: FocusScope) -> Bool {
        switch self {
        case .live, .agents, .reports, .visualize, .inspect:
            return true
        case .alerts:
            return scope.hosts.isEmpty
        case .ask, .rules, .devices, .coverage, .capture:
            return false
        }
    }
}

/// The sidebar in task-focused groups rather than one long column.
///
/// A flat list stops being scannable quickly: the eye has to read every label to find the one it wants.
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

    var items: [SidebarItem] {
        let order: [SidebarItem]
        switch self {
        case .traffic: order = [.live, .agents, .reports, .visualize, .alerts]
        case .investigate: order = [.ask, .inspect]
        case .control: order = [.rules]
        case .sources: order = [.devices, .coverage, .capture]
        }
        return order.filter { SidebarItem.availableCases.contains($0) }
    }
}

/// The three views inside Rules. This lives with the shared navigation state so an app-wide notice can take someone
/// straight to a changed pack, while ordinary rule links always land back on the rule list.
enum RulesTab: String, CaseIterable, Identifiable {
    case rules, packs, activity

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .rules: return L("Rules")
        case .packs: return L("Packs")
        case .activity: return L("What they did")
        }
    }
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
    var start: Date? = nil
    var end: Date?
    var duration: TimeInterval? = nil
    var preset: HistoryRangePreset? = nil
    var id = UUID()
}

/// Shared navigation state so screens can link to each other (Live/Alerts → Reports).
@MainActor
final class AppNavigation: ObservableObject {
    @Published private(set) var selection: SidebarItem = {
        let restored = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "FLScreen") ?? "") ?? .live
        return SidebarItem.availableCases.contains(restored) ? restored : .live
    }()
    @Published var rulesTab: RulesTab = .rules
    @Published var reportRequest: ReportRequest?
    @Published var inspectRequest: InspectRequest?
    @Published var ruleRequest: RuleRequest?

    private struct TrailEntry {
        var item: SidebarItem
        var report: ReportRequest?
    }

    private var trail: [TrailEntry] = []
    private var currentReportScope: ReportRequest?

    var backDestination: SidebarItem? { trail.last?.item }

    /// Sidebar choices start a new task. In-content links use `followLink` below so their exact origin can be restored.
    func show(_ item: SidebarItem) {
        guard SidebarItem.availableCases.contains(item) else { return }
        trail.removeAll()
        if item == .rules { rulesTab = .rules }
        selection = item
    }

    func updateCurrentReportScope(filter: TrafficFilter, granularity: Granularity,
                                  startDate: Date, endDate: Date, followNow: Bool,
                                  preset: HistoryRangePreset?) {
        currentReportScope = ReportRequest(filter: filter, granularity: granularity,
                                           start: followNow ? nil : startDate,
                                           end: followNow ? nil : endDate,
                                           duration: endDate.timeIntervalSince(startDate),
                                           preset: preset)
    }

    func goBack() {
        guard let entry = trail.popLast() else { return }
        if entry.item == .reports { reportRequest = entry.report }
        selection = entry.item
    }

    private func followLink(to item: SidebarItem) {
        guard SidebarItem.availableCases.contains(item), selection != item else { return }
        trail.append(TrailEntry(item: selection,
                                report: selection == .reports ? currentReportScope : nil))
        selection = item
    }

    func writeRule(_ rule: Rule) {
        ruleRequest = RuleRequest(rule: rule)
        showRules()
    }

    func showRules() {
        show(.rules)
    }

    func showPackReviews() {
        show(.rules)
        rulesTab = .packs
    }

    func showReport(filter: TrafficFilter, granularity: Granularity? = nil,
                    start: Date? = nil, end: Date? = nil) {
        reportRequest = ReportRequest(filter: filter, granularity: granularity,
                                      start: start, end: end)
        followLink(to: .reports)
    }

    /// Open Inspect already looking at one app, host or address.
    ///
    /// Inspect searches one field across hosts, paths, app names, tools and bodies, so "show me this row's
    /// traffic" is that field pre-filled rather than a second filtering mechanism. It also means the search
    /// stays visible and editable: someone who arrives here can widen or narrow it without going back.
    func showInspect(search: String, potentialHarmOnly: Bool = false) {
        guard SidebarItem.availableCases.contains(.inspect) else { return }
        inspectRequest = InspectRequest(search: search, potentialHarmOnly: potentialHarmOnly)
        followLink(to: .inspect)
    }

    /// Scope Inspect to one app or one destination, rather than searching for its name.
    ///
    /// The first version of this put the name in the search field, which reads well — visible, editable — but
    /// Inspect searches response bodies too, so "Claude Code" matched every page whose HTML happens to contain
    /// those words. The scope is still shown and still removable; it is just no longer a text match.
    func showInspect(app: (bundleID: String, name: String)? = nil,
                     appIDs: [String] = [], appName: String? = nil, host: String? = nil,
                     hostIncludesSubdomains: Bool = true,
                     includeAttributedChildren: Bool = false, agentParent: String? = nil,
                     mcpServer: String? = nil, potentialHarmOnly: Bool = false) {
        guard SidebarItem.availableCases.contains(.inspect) else { return }
        inspectRequest = InspectRequest(search: "", appID: app?.bundleID,
                                       appIDs: app == nil ? appIDs : [], appName: app?.name ?? appName, host: host,
                                       hostIncludesSubdomains: hostIncludesSubdomains,
                                       includeAttributedChildren: includeAttributedChildren,
                                       agentParent: agentParent, mcpServer: mcpServer,
                                       potentialHarmOnly: potentialHarmOnly)
        followLink(to: .inspect)
    }
}

@MainActor
enum InspectNavigationScope {
    static func canInspect(_ filter: TrafficFilter, requireDestination: Bool = true) -> Bool {
        if filter.owner != nil || filter.domainSuffix != nil || filter.appProtocol != nil || filter.channel != nil {
            return false
        }
        // Inspected exchanges retain the requested host but not its resolved address. An address-only Reports row
        // therefore cannot be represented honestly; a host row may still carry its observed address as evidence.
        if filter.remoteIP != nil, filter.domain == nil { return false }
        guard let domain = filter.domain else { return !requireDestination }
        return HostCanonicalizer.host(domain) != nil && HostCanonicalizer.address(domain) == nil
    }

    static func showInspect(_ nav: AppNavigation, filter: TrafficFilter, sourceTitle: String? = nil,
                            requireDestination: Bool = true, potentialHarmOnly: Bool = false) {
        guard canInspect(filter, requireDestination: requireDestination) else { return }
        let app = filter.bundleIDs.isEmpty
            ? filter.bundleID.flatMap { $0.isEmpty ? nil : ($0, sourceTitle ?? $0) }
            : nil
        let host = filter.domain.flatMap(HostCanonicalizer.host)
        nav.showInspect(app: app, appIDs: filter.bundleIDs, appName: sourceTitle,
                        host: host, hostIncludesSubdomains: false,
                        includeAttributedChildren: filter.includeAttributedChildren,
                        agentParent: filter.agentParent, mcpServer: filter.mcpServer,
                        potentialHarmOnly: potentialHarmOnly)
    }
}

/// A request from another screen to open Inspect scoped to something.
struct InspectRequest: Equatable {
    var search: String
    /// The exact app identity or merged alias set to scope to, and the name to show on the chip that says so.
    var appID: String? = nil
    var appIDs: [String] = []
    var appName: String? = nil
    var host: String? = nil
    var hostIncludesSubdomains = true
    var includeAttributedChildren = false
    var agentParent: String? = nil
    var mcpServer: String? = nil
    /// Explicitly displayed and removable in Inspect; Reports uses it for the potential-harm drill-in.
    var potentialHarmOnly = false
    var id = UUID()
}
