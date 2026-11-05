import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case live, agents, reports, alerts, rules, ask, inspect, sources, visualize
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
        case .rules: return "policies"
        case .ask: return "ask"
        case .inspect: return "inspection"
        case .sources: return "sources"
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
        case .rules: return "Policies"
        case .ask: return "Ask"
        case .inspect: return "Inspect"
        case .sources: return "Sources"
        }
    }

    @MainActor var title: String {
        switch self {
        case .live: return L("Live")
        case .agents: return L("AI Agents")
        case .reports: return L("History")
        case .visualize: return L("Connections")
        case .alerts: return L("Alerts")
        case .rules: return L("Policies")
        case .ask: return L("Ask")
        case .inspect: return L("Inspect")
        case .sources: return L("Sources")
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
        case .inspect: return "lock.open.display"
        case .sources: return "antenna.radiowaves.left.and.right"
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
        case .sources: return .sources
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
        case .ask, .rules, .sources:
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
        case .sources: order = [.sources]
        }
        return order.filter { SidebarItem.availableCases.contains($0) }
    }
}

/// The three sections in the single Sources destination. The cases remain navigation state so restored windows,
/// screenshot arguments and links can scroll to the exact operational section without hiding the other two.
enum SourcesTab: String, CaseIterable, Identifiable, Sendable {
    case collector, devices, coverage

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .collector: return L("Collector")
        case .devices: return L("Devices")
        case .coverage: return L("Coverage")
        }
    }

    var anchorID: String { "sources-\(rawValue)" }

    /// `devices` and `coverage` were once standalone screens, then visible tabs. Both old forms still restore to
    /// the corresponding section; an explicit modern section always wins over the legacy screen value.
    static func restored(explicitRawValue: String?, legacyScreenRawValue: String?) -> SourcesTab {
        if let explicitRawValue, let explicit = SourcesTab(rawValue: explicitRawValue) { return explicit }
        switch legacyScreenRawValue {
        case "devices": return .devices
        case "coverage": return .coverage
        default: return .collector
        }
    }
}

/// Alert review and its detection tuning share a destination, but app-wide alert links must still be able to select
/// the review list explicitly instead of inheriting whichever tab happened to be visible.
enum AlertsTab: String, CaseIterable, Identifiable {
    case alerts, detection

    var id: String { rawValue }
    @MainActor var title: String { self == .alerts ? L("Alerts") : L("Detection") }
}

/// The two views inside Policies. The raw `rules` value is deliberately retained: restored windows and preferences
/// written before the product rename must keep landing on the inventory rather than silently resetting.
enum RulesTab: String, CaseIterable, Identifiable {
    case rules, activity

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .rules: return L("Policies")
        case .activity: return L("Activity")
        }
    }

    /// `packs` was a visible tab through 0.17.3. It now restores to the unified inventory, where managed packs have
    /// their own section. Unknown future values take the same conservative path.
    static func restored(from rawValue: String?) -> RulesTab {
        rawValue == RulesTab.activity.rawValue ? .activity : .rules
    }

    static func restoresManagedPackFocus(from rawValue: String?) -> Bool {
        rawValue == "packs"
    }
}

enum AgentPolicySection: Equatable, Sendable { case allowlist, guardrails }

struct AgentPolicyRequest: Equatable, Sendable {
    var agentID: String
    var section: AgentPolicySection
    var id = UUID()
}

enum InspectPolicySection: Equatable, Sendable { case mocks, requestRewrites, responseTransforms }

/// A precise request into the policy inventory. It is intentionally source-shaped rather than carrying an editor:
/// each destination still owns its consent, validation, and save behavior.
enum PolicyDestination: Equatable, Sendable {
    case rule(UUID)
    case allowlist(String)
    case managedPack(String?)
    case guardrail(id: UUID, agentID: String)
    case mock(UUID)
    case requestRewrite(UUID)
    case responseTransform(UUID)
}

struct PolicyRequest: Equatable, Sendable {
    var destination: PolicyDestination
    var id = UUID()
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
        let raw = UserDefaults.standard.string(forKey: "FLScreen") ?? ""
        // Preserve restored windows and screenshot arguments from before Devices, Coverage and Capture became tabs.
        let restored = ["devices", "coverage", "capture"].contains(raw)
            ? SidebarItem.sources
            : SidebarItem(rawValue: raw) ?? .live
        return SidebarItem.availableCases.contains(restored) ? restored : .live
    }()
    @Published var sourcesTab: SourcesTab = {
        let defaults = UserDefaults.standard
        return SourcesTab.restored(explicitRawValue: defaults.string(forKey: "FLSourcesTab"),
                                   legacyScreenRawValue: defaults.string(forKey: "FLScreen"))
    }()
    /// A separate pulse makes a repeated link to the already-selected section scroll again.
    @Published private(set) var sourcesRequestID = UUID()
    @Published var alertsTab: AlertsTab = .alerts
    @Published var rulesTab: RulesTab = {
        RulesTab.restored(from: UserDefaults.standard.string(forKey: "FLRulesTab"))
    }()
    @Published var reportRequest: ReportRequest?
    @Published var inspectRequest: InspectRequest?
    @Published var ruleRequest: RuleRequest?
    @Published var policyRequest: PolicyRequest? = {
        RulesTab.restoresManagedPackFocus(from: UserDefaults.standard.string(forKey: "FLRulesTab"))
            ? PolicyRequest(destination: .managedPack(nil)) : nil
    }()
    @Published var agentPolicyRequest: AgentPolicyRequest?

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
        if item == .alerts { alertsTab = .alerts }
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

    func showAlerts() {
        show(.alerts)
    }

    func showRules() {
        show(.rules)
    }

    func showSources(_ tab: SourcesTab = .collector) {
        sourcesTab = tab
        sourcesRequestID = UUID()
        show(.sources)
    }

    func showPackReviews() {
        show(.rules)
        policyRequest = PolicyRequest(destination: .managedPack(nil))
    }

    func showPolicyPack(_ packID: String) {
        show(.rules)
        policyRequest = PolicyRequest(destination: .managedPack(packID))
    }

    func showPolicy(_ destination: PolicyDestination) {
        show(.rules)
        policyRequest = PolicyRequest(destination: destination)
    }

    func showAgentPolicy(agentID: String, section: AgentPolicySection) {
        agentPolicyRequest = AgentPolicyRequest(agentID: agentID, section: section)
        followLink(to: .agents)
    }

    func showInspectionPolicy(_ section: InspectPolicySection) {
        guard SidebarItem.availableCases.contains(.inspect) else { return }
        inspectRequest = InspectRequest(search: "", policySection: section)
        followLink(to: .inspect)
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
    /// Opens setup on the contextual editor that owns this kind of policy.
    var policySection: InspectPolicySection? = nil
    var id = UUID()
}
