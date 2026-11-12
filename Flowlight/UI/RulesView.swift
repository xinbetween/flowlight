import SwiftUI

struct PolicyInventoryCapabilities: Equatable, Sendable {
    var inspectionPolicies: Bool
    var responseTransforms: Bool = true

    static var current: PolicyInventoryCapabilities {
        let product = ProductCapabilities.current
        return PolicyInventoryCapabilities(
            inspectionPolicies: product.proxyInspection,
            responseTransforms: product.responseTransforms
        )
    }
}

enum PolicyInventoryKind: String, CaseIterable, Sendable {
    case networkRule = "rule"
    case agentAllowlist = "allowlist"
    case managedPack = "pack"
    case guardrail
    case mock
    case requestRewrite = "request-rewrite"
    case responseTransform = "response-transform"

    var requiresInspection: Bool {
        switch self {
        case .guardrail, .mock, .requestRewrite, .responseTransform: return true
        case .networkRule, .agentAllowlist, .managedPack: return false
        }
    }

    @MainActor var sectionTitle: String {
        switch self {
        case .networkRule: return L("Network rules")
        case .agentAllowlist: return L("Agent allowlists")
        case .managedPack: return L("Managed packs")
        case .guardrail: return L("Agent guardrails")
        case .mock: return L("Mock responses")
        case .requestRewrite: return L("Request rewrites")
        case .responseTransform: return L("Response transforms")
        }
    }

    var symbol: String {
        switch self {
        case .networkRule: return "hand.raised"
        case .agentAllowlist: return "checklist"
        case .managedPack: return "shippingbox"
        case .guardrail: return "wrench.and.screwdriver"
        case .mock: return "wand.and.stars"
        case .requestRewrite: return "slider.horizontal.3"
        case .responseTransform: return "arrow.left.arrow.right"
        }
    }
}

enum PolicyInventoryID {
    static func make(_ kind: PolicyInventoryKind, sourceID: String) -> String {
        "\(kind.rawValue):\(sourceID)"
    }
}

enum PolicyEffectState: Equatable, Sendable {
    case effective
    case httpOnly
    case reportingOnly
    case watchingOnly
    case waiting
    case off
    case needsReview
    case unavailable
    case failed

    var isEffective: Bool {
        switch self {
        case .effective, .httpOnly, .reportingOnly, .watchingOnly: return true
        case .waiting, .off, .needsReview, .unavailable, .failed: return false
        }
    }

    @MainActor var title: String {
        switch self {
        case .effective: return L("In effect")
        case .httpOnly: return L("HTTP only")
        case .reportingOnly: return L("Reporting only")
        case .watchingOnly: return L("Watching only")
        case .waiting: return L("Waiting")
        case .off: return L("Off")
        case .needsReview: return L("Needs review")
        case .unavailable: return L("Unavailable")
        case .failed: return L("Not applying")
        }
    }
}

struct PolicyInventoryItem: Identifiable, Equatable, Sendable {
    var kind: PolicyInventoryKind
    var sourceID: String
    var title: String
    var detail: String
    /// The persisted switch or configuration intent. This is not evidence that the policy can currently act.
    var isEnabled: Bool
    var effect: PolicyEffectState
    var reason: String?
    var destination: PolicyDestination
    var id: String { PolicyInventoryID.make(kind, sourceID: sourceID) }

    func isVisible(in capabilities: PolicyInventoryCapabilities) -> Bool {
        if kind == .responseTransform { return capabilities.responseTransforms }
        return capabilities.inspectionPolicies || !kind.requiresInspection
    }
}

enum PolicyInventoryBuilder {
    @MainActor
    static func build(rules: [Rule], allowlists: [String: AgentPolicy], packs: [RulePackDefinition],
                      unavailablePacks: [RulePackConfiguration] = [],
                      packConfiguration: (String) -> RulePackConfiguration,
                      packNeedsReview: (RulePackDefinition) -> Bool = { _ in false },
                      packStatus: RulePackStore.ApplyStatus = .off,
                      guardrails: [Guardrail], mocks: [MockRule], rewrites: [RewriteRule],
                      transforms: [ResponseTransformRule], extensionRunning: Bool = true,
                      canBlock: Bool = true, inspectionEnabled: Bool = true, inspectionRunning: Bool = true,
                      inspectionTrusted: Bool = true, inspectionAttributionReady: Bool = true,
                      rulesPaused: Bool = false, now: Date = Date(), ruleSession: String = RuleStore.session,
                      capabilities: PolicyInventoryCapabilities = .current) -> [PolicyInventoryItem] {
        let attributionReason = L("The proxy is ready, but trusted app attribution is unavailable. Enable Flowlight under Content filter, then press Check Setup. App-scoped policies fail open until attribution is available.")
        func attributionEffect(_ required: Bool) -> (PolicyEffectState, String?)? {
            guard required, inspectionEnabled, inspectionRunning, !inspectionAttributionReady else { return nil }
            return (.waiting, attributionReason)
        }
        func inspectionEffect(_ enabled: Bool, requiresAttribution: Bool = false) -> (PolicyEffectState, String?) {
            guard enabled else { return (.off, L("This policy is switched off.")) }
            guard inspectionEnabled else { return (.waiting, L("HTTPS inspection is off.")) }
            guard inspectionRunning else { return (.waiting, L("HTTPS inspection is not running.")) }
            if let effect = attributionEffect(requiresAttribution) { return effect }
            guard inspectionTrusted else {
                return (.httpOnly, L("In effect for plain HTTP. HTTPS waits until the Flowlight inspection certificate is trusted."))
            }
            return (.effective, nil)
        }

        var items = rules.map { rule -> PolicyInventoryItem in
            let effect: PolicyEffectState
            let reason: String?
            if !rule.enabled {
                (effect, reason) = (.off, L("This rule is switched off."))
            } else if rulesPaused {
                (effect, reason) = (.waiting, L("Network blocking is paused."))
            } else if !rule.isUsable {
                (effect, reason) = (.waiting, L("This one-off rule has already been used."))
            } else if !rule.schedule.isActive(at: now, session: ruleSession) {
                (effect, reason) = (.waiting, L("This rule is outside its scheduled time."))
            } else if let limitation = RuleWords.limitation(rule, extensionRunning: extensionRunning,
                                                             inspecting: inspectionEnabled && inspectionRunning) {
                (effect, reason) = (.watchingOnly, limitation)
            } else if rule.engine != .flow {
                (effect, reason) = inspectionEffect(true, requiresAttribution: !rule.app.isEmpty)
            } else if let attribution = attributionEffect(!rule.app.isEmpty) {
                (effect, reason) = attribution
            } else {
                (effect, reason) = (.effective, nil)
            }
            return PolicyInventoryItem(kind: .networkRule, sourceID: rule.id.uuidString.lowercased(),
                                       title: RuleWords.title(rule),
                                       detail: rule.destination.isEmpty ? L("Every destination") : rule.destination,
                                       isEnabled: rule.enabled, effect: effect, reason: reason,
                                       destination: .rule(rule.id))
        }
        items += allowlists.keys.sorted().compactMap { agentID in
            guard let policy = allowlists[agentID] else { return nil }
            let detail = policy.patterns.isEmpty ? L("No listed destinations")
                : (policy.patterns.count == 1 ? L("1 listed destination") : L("%lld listed destinations", policy.patterns.count))
            let effect: PolicyEffectState
            let reason: String?
            if !policy.enabled {
                (effect, reason) = (.off, L("This allowlist is switched off."))
            } else if !policy.enforce {
                (effect, reason) = (.reportingOnly, L("Unlisted destinations raise alerts but are not blocked."))
            } else if !canBlock {
                (effect, reason) = (.reportingOnly, L("Blocking is unavailable; unlisted destinations still raise alerts."))
            } else if let attribution = attributionEffect(true) {
                (effect, reason) = attribution
            } else {
                (effect, reason) = (.effective, nil)
            }
            return PolicyInventoryItem(kind: .agentAllowlist, sourceID: agentID, title: agentID, detail: detail,
                                       isEnabled: policy.enabled, effect: effect, reason: reason,
                                       destination: .allowlist(agentID))
        }
        items += packs.map { pack in
            let configuration = packConfiguration(pack.id)
            let effect: PolicyEffectState
            let reason: String?
            if packNeedsReview(pack) {
                (effect, reason) = (.needsReview, L("Review the changed pack before it can keep applying."))
            } else if !configuration.enabled {
                (effect, reason) = (.off, L("This pack is switched off."))
            } else {
                switch packStatus {
                case .enforcing where canBlock:
                    if let attribution = attributionEffect(configuration.scope == .selectedApps) {
                        (effect, reason) = attribution
                    } else {
                        (effect, reason) = (.effective, nil)
                    }
                case .watchingOnly, .enforcing:
                    (effect, reason) = (.watchingOnly, L("The pack is matching destinations but cannot block them here."))
                case .applying, .ready:
                    (effect, reason) = (.waiting, L("The pack is waiting for the active filter to apply it."))
                case .incompatible(let message), .failed(let message):
                    (effect, reason) = (.failed, message)
                case .off:
                    (effect, reason) = (.waiting, L("The managed-pack engine is not applying this configuration."))
                }
            }
            return PolicyInventoryItem(kind: .managedPack, sourceID: pack.id, title: L(pack.manifest.titleKey),
                                       detail: L("%lld destinations", pack.entries.count),
                                       isEnabled: configuration.enabled, effect: effect, reason: reason,
                                       destination: .managedPack(pack.id))
        }
        let knownPackIDs = Set(packs.map(\.id))
        items += unavailablePacks.filter { !knownPackIDs.contains($0.packID) }.map { configuration in
            PolicyInventoryItem(kind: .managedPack, sourceID: configuration.packID, title: configuration.packID,
                                detail: L("No longer in the official catalog"), isEnabled: configuration.enabled,
                                effect: .unavailable,
                                reason: L("Blocking stopped automatically. Acknowledge this change after review."),
                                destination: .managedPack(configuration.packID))
        }
        items += guardrails.map { guardrail in
            let (effect, reason) = inspectionEffect(guardrail.enabled, requiresAttribution: !guardrail.agent.isEmpty)
            return PolicyInventoryItem(kind: .guardrail, sourceID: guardrail.id.uuidString.lowercased(),
                                       title: guardrail.localizedTitle,
                                       detail: guardrail.agent.isEmpty ? L("Every agent") : guardrail.agent,
                                       isEnabled: guardrail.enabled, effect: effect, reason: reason,
                                       destination: .guardrail(id: guardrail.id, agentID: guardrail.agent))
        }
        items += mocks.map { rule in
            let (effect, reason) = inspectionEffect(rule.enabled)
            return PolicyInventoryItem(kind: .mock, sourceID: rule.id.uuidString.lowercased(), title: rule.title,
                                       detail: "\(rule.method.isEmpty ? "ANY" : rule.method.uppercased()) \(rule.host)\(rule.path)",
                                       isEnabled: rule.enabled, effect: effect, reason: reason,
                                       destination: .mock(rule.id))
        }
        items += rewrites.map { rule in
            let (effect, reason) = inspectionEffect(rule.enabled)
            return PolicyInventoryItem(kind: .requestRewrite, sourceID: rule.id.uuidString.lowercased(), title: rule.title,
                                       detail: "\(rule.method.isEmpty ? "ANY" : rule.method.uppercased()) \(rule.host)\(rule.path)",
                                       isEnabled: rule.enabled, effect: effect, reason: reason,
                                       destination: .requestRewrite(rule.id))
        }
        items += transforms.map { rule in
            let (effect, reason) = inspectionEffect(rule.enabled)
            return PolicyInventoryItem(kind: .responseTransform, sourceID: rule.id.uuidString.lowercased(), title: rule.title,
                                       detail: "\(rule.method.isEmpty ? "ANY" : rule.method.uppercased()) \(rule.host)\(rule.path)",
                                       isEnabled: rule.enabled, effect: effect, reason: reason,
                                       destination: .responseTransform(rule.id))
        }
        return items.filter { $0.isVisible(in: capabilities) }
    }
}

enum PolicyActivityEffect: String, Equatable, Hashable, Sendable {
    case blocked
    case allowed
    case packBlocked = "pack-blocked"
    case allowlistViolation = "allowlist-violation"
    case guardrailApplied = "guardrail-applied"
    case mocked
    case requestRewritten = "request-rewritten"
    case responseTransformed = "response-transformed"
}

enum PolicyActivitySource: Equatable, Sendable {
    case rule(RuleEventRecord)
    case managedPack(RulePackEventRecord)
    case generic
}

struct PolicyActivityItem: Identifiable, Equatable, Sendable {
    var id: String
    var timestamp: Date
    var kind: PolicyInventoryKind
    var effect: PolicyActivityEffect
    var title: String
    var detail: String
    var policyID: String?
    var source: PolicyActivitySource = .generic
}

enum NetworkRuleGrouping {
    static func inForce(_ rules: [Rule], at now: Date, session: String) -> [Rule] {
        rules.filter { $0.enabled && $0.isUsable && $0.schedule.isActive(at: now, session: session) }
    }

    static func resting(_ rules: [Rule], at now: Date, session: String) -> [Rule] {
        rules.filter { !($0.enabled && $0.isUsable && $0.schedule.isActive(at: now, session: session)) }
    }
}

enum PolicyActivityBuilder {
    private struct RefusalKey: Hashable {
        var bundleID: String
        var destination: String
        var port: Int
        var path: String
        var method: String
    }

    private struct GuardrailRefusalKey: Hashable {
        var bundleID: String
        var destination: String
        var port: Int
        var method: String
    }

    static func build(ruleEvents: [RuleEventRecord], packEvents: [RulePackEventRecord], alerts: [AlertRecord],
                      exchanges: [HTTPExchange], rules: [Rule], guardrails: [Guardrail], packs: [RulePackDefinition],
                      mocks: [MockRule], rewrites: [RewriteRule], transforms: [ResponseTransformRule],
                      policies: [AgentPolicy] = [],
                      capabilities: PolicyInventoryCapabilities = .current) -> [PolicyActivityItem] {
        let ruleIDs = Set(rules.map(\.id))
        let guardrailIDs = Set(guardrails.map(\.id))
        let packIDs = Set(packs.map(\.id))
        let mockIDs = Set(mocks.map(\.id))
        let rewriteIDs = Set(rewrites.map(\.id))
        let transformIDs = Set(transforms.map(\.id))
        let refusalTimes = Dictionary(grouping: ruleEvents.filter {
            $0.action == .block && $0.engine != .guardrail
        }) { event in
            RefusalKey(bundleID: event.bundleID, destination: event.destination, port: Int(event.port),
                       path: event.path, method: event.method)
        }.mapValues { $0.map(\.timestamp) }
        let guardrailRefusalTimes = Dictionary(grouping: ruleEvents.filter {
            $0.action == .block && $0.engine == .guardrail
        }) { event in
            GuardrailRefusalKey(bundleID: event.bundleID, destination: event.destination,
                                port: Int(event.port), method: event.method)
        }.mapValues { $0.map(\.timestamp) }
        var activity = ruleEvents.map { event -> PolicyActivityItem in
            let isGuardrail = event.engine == .guardrail || guardrailIDs.contains(event.ruleID)
            let title = rules.first(where: { $0.id == event.ruleID }).map(RuleWords.title)
                ?? guardrails.first(where: { $0.id == event.ruleID })?.localizedTitle ?? L("A policy since deleted")
            let exists = isGuardrail ? guardrailIDs.contains(event.ruleID) : ruleIDs.contains(event.ruleID)
            return PolicyActivityItem(
                id: "rule-event:\(event.id)", timestamp: event.timestamp,
                kind: isGuardrail ? .guardrail : .networkRule,
                effect: isGuardrail ? .guardrailApplied : (event.action == .block ? .blocked : .allowed),
                title: title, detail: event.path.isEmpty ? "\(event.destination):\(event.port)" : "\(event.method) \(event.destination)\(event.path)",
                policyID: exists ? PolicyInventoryID.make(isGuardrail ? .guardrail : .networkRule,
                                                          sourceID: event.ruleID.uuidString.lowercased()) : nil,
                source: isGuardrail ? .generic : .rule(event))
        }
        activity += packEvents.map { event in
            let title = packs.first(where: { $0.id == event.packID }).map { L($0.manifest.titleKey) } ?? event.packID
            return PolicyActivityItem(id: "pack-event:\(event.id)", timestamp: event.lastAt, kind: .managedPack,
                                      effect: .packBlocked,
                                      title: title, detail: L("%@ · %lld connections", event.host, event.count),
                                      policyID: packIDs.contains(event.packID)
                                          ? PolicyInventoryID.make(.managedPack, sourceID: event.packID) : nil,
                                      source: .managedPack(event))
        }
        activity += alerts.filter { $0.kind == AnomalyEngine.Kind.allowlistViolation.rawValue }.map { alert in
            let policy = AgentPolicy.resolve(
                policies,
                identities: [alert.bundleID, alert.appName]
            )
            return PolicyActivityItem(
                id: "alert:\(alert.id)", timestamp: alert.timestamp, kind: .agentAllowlist,
                effect: .allowlistViolation,
                title: alert.appName, detail: alert.detail,
                policyID: policy.map {
                    PolicyInventoryID.make(.agentAllowlist, sourceID: $0.agentID)
                }
            )
        }
        for exchange in exchanges {
            let source = exchange.id.map(String.init) ?? "\(exchange.started.timeIntervalSince1970)"
            let detail = "\(exchange.method) \(exchange.host)\(exchange.path)"
            if let value = exchange.guardrail {
                if let references = InspectionPolicyReference.decode(value) {
                    for reference in references {
                        activity.append(PolicyActivityItem(
                            id: "exchange:\(source):guardrail:\(reference.id.uuidString.lowercased())",
                            timestamp: exchange.started, kind: .guardrail, effect: .guardrailApplied,
                            title: reference.title, detail: detail,
                            policyID: guardrailIDs.contains(reference.id)
                                ? PolicyInventoryID.make(.guardrail, sourceID: reference.id.uuidString.lowercased()) : nil
                        ))
                    }
                } else {
                    let policy = guardrails.first { $0.localizedTitle == value || $0.title == value }
                    activity.append(PolicyActivityItem(id: "exchange:\(source):guardrail", timestamp: exchange.started,
                                                       kind: .guardrail, effect: .guardrailApplied, title: value, detail: detail,
                                                       policyID: policy.map { PolicyInventoryID.make(.guardrail, sourceID: $0.id.uuidString.lowercased()) }))
                }
            }
            if let value = exchange.mockRule {
                if let references = InspectionPolicyReference.decode(value) {
                    for reference in references {
                        activity.append(PolicyActivityItem(
                            id: "exchange:\(source):mock:\(reference.id.uuidString.lowercased())",
                            timestamp: exchange.started, kind: .mock, effect: .mocked,
                            title: reference.title, detail: detail,
                            policyID: mockIDs.contains(reference.id)
                                ? PolicyInventoryID.make(.mock, sourceID: reference.id.uuidString.lowercased()) : nil
                        ))
                    }
                } else {
                    let policy = mocks.first(where: { $0.title == value })
                    let exchangePath = exchange.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? exchange.path
                    let refusalKey = RefusalKey(bundleID: exchange.bundleID, destination: exchange.host,
                                                port: exchange.port, path: exchangePath, method: exchange.method)
                    let guardrailKey = GuardrailRefusalKey(bundleID: exchange.bundleID,
                                                            destination: exchange.host, port: exchange.port,
                                                            method: exchange.method)
                    let hasRefusalEvent = (refusalTimes[refusalKey] ?? [])
                        .contains { abs($0.timeIntervalSince(exchange.started)) <= 1 }
                        || (guardrailRefusalTimes[guardrailKey] ?? [])
                        .contains { abs($0.timeIntervalSince(exchange.started)) <= 1 }
                    // Before stable mock references, request-level blocks and guardrail refusals used the same answer
                    // machinery. Their correlated RuleEvent is already in Activity; an uncorrelated value is retained
                    // as mock history even after its current configuration is renamed or deleted.
                    if policy != nil || !hasRefusalEvent {
                        activity.append(PolicyActivityItem(
                            id: "exchange:\(source):mock", timestamp: exchange.started,
                            kind: .mock, effect: .mocked, title: value, detail: detail,
                            policyID: policy.map { PolicyInventoryID.make(.mock, sourceID: $0.id.uuidString.lowercased()) }
                        ))
                    }
                }
            }
            if let value = exchange.requestRewrite {
                if let references = InspectionPolicyReference.decode(value) {
                    for reference in references {
                        activity.append(PolicyActivityItem(
                            id: "exchange:\(source):request-rewrite:\(reference.id.uuidString.lowercased())",
                            timestamp: exchange.started, kind: .requestRewrite, effect: .requestRewritten,
                            title: reference.title, detail: detail,
                            policyID: rewriteIDs.contains(reference.id)
                                ? PolicyInventoryID.make(.requestRewrite, sourceID: reference.id.uuidString.lowercased()) : nil
                        ))
                    }
                } else {
                    let policy = rewrites.first { $0.title == value }
                    activity.append(PolicyActivityItem(id: "exchange:\(source):request-rewrite", timestamp: exchange.started,
                                                       kind: .requestRewrite, effect: .requestRewritten, title: value, detail: detail,
                                                       policyID: policy.map { PolicyInventoryID.make(.requestRewrite, sourceID: $0.id.uuidString.lowercased()) }))
                }
            }
            if let value = exchange.responseTransform {
                if let references = InspectionPolicyReference.decode(value) {
                    for reference in references {
                        activity.append(PolicyActivityItem(
                            id: "exchange:\(source):response-transform:\(reference.id.uuidString.lowercased())",
                            timestamp: exchange.started, kind: .responseTransform, effect: .responseTransformed,
                            title: reference.title, detail: detail,
                            policyID: transformIDs.contains(reference.id)
                                ? PolicyInventoryID.make(.responseTransform, sourceID: reference.id.uuidString.lowercased()) : nil
                        ))
                    }
                } else {
                    let policy = transforms.first { $0.title == value }
                    activity.append(PolicyActivityItem(id: "exchange:\(source):response-transform", timestamp: exchange.started,
                                                       kind: .responseTransform, effect: .responseTransformed, title: value, detail: detail,
                                                       policyID: policy.map { PolicyInventoryID.make(.responseTransform, sourceID: $0.id.uuidString.lowercased()) }))
                }
            }
        }
        return activity.filter { capabilities.inspectionPolicies || !$0.kind.requiresInspection }
            .sorted { ($0.timestamp, $0.id) > ($1.timestamp, $1.id) }
    }
}

/// Every policy Flowlight has been given, what each one is doing, and what it has changed.
///
/// The screen answers three questions, in the order people ask them: what have I said, is it actually happening,
/// and why is this getting through? The last two are why the list carries a limitation beside a rule the current
/// engine can't carry out, and why a relaxation appears in the feed beside a refusal.
struct RulesView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var templates = RuleTemplateRequests.shared
    @State private var sheet: Sheet?
    @State private var now = Date()
    @State private var allowlists: [String: AgentPolicy] = [:]
    @State private var alerts: [AlertRecord] = []
    @State private var exchanges: [HTTPExchange] = []
    @State private var hasMorePolicyEffects = false
    @State private var loadingMorePolicyEffects = false
    @State private var policyEffectSince = Date.distantPast
    @State private var focusPolicyID: String?
    @State private var packSaveErrors: [String: String] = [:]

    private static let policyEffectPageSize = 500

    /// One sheet at a time, named rather than implied by two booleans — the editor and the library are alternatives
    /// and the type should say so.
    private enum Sheet: Identifiable {
        case editor(Rule, isNew: Bool)
        case library(RuleTemplate.ID?, RuleTemplate.Subject)
        case pack(RulePackDefinition, RulePackEditorDraft.Intent)
        case globalGuardrails(UUID?)

        var id: String {
            switch self {
            case .editor(let rule, _): return "editor-\(rule.id)"
            case .library(let focus, _): return "library-\(focus ?? "all")"
            case .pack(let pack, let intent): return "pack-\(pack.id)-\(intent)"
            case .globalGuardrails(let focus): return "global-guardrails-\(focus?.uuidString ?? "all")"
            }
        }
    }

    private var store: RuleStore { monitor.rules }

    var body: some View {
        Group {
            switch nav.rulesTab {
            case .rules: inventory
            case .activity: activityFeed
            }
        }
        .navigationTitle(L("Policies"))
        // The title bar carries the state that would otherwise need a trip to the screen to discover: how many
        // rules are live, and whether they are standing down.
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .sheet(item: $sheet) { which in
            switch which {
            case .editor(let rule, let isNew):
                RuleEditor(rule: rule, isNew: isNew) { store.save($0) }
            case .library(let focus, let subject):
                // The library doesn't hand off to the editor: a card already shows every rule it would write and
                // the caveat that goes with it, so the look has happened. Anything that wants adjusting is one
                // click away in the list afterwards.
                RuleTemplateLibrary(focus: focus, subject: subject) { rules in
                    for rule in rules { store.save(rule) }
                }
            case .pack(let pack, let intent):
                RulePackEditor(pack: pack, receipt: monitor.rulePacks.reviewReceipt(for: pack),
                               saved: monitor.rulePacks.configuration(for: pack.id), intent: intent,
                               packs: monitor.rulePacks, rules: store)
            case .globalGuardrails(let focus):
                GlobalGuardrailsSheet(store: monitor.guardrails, focus: focus)
            }
        }
        .onChange(of: nav.ruleRequest) { _, request in
            guard let request else { return }
            sheet = .editor(request.rule, isNew: true)
            nav.ruleRequest = nil
        }
        .onChange(of: templates.pending?.id) { _, _ in takeTemplateRequest() }
        .onChange(of: nav.policyRequest, initial: true) { _, request in
            guard let request else { return }
            handle(request.destination)
            nav.policyRequest = nil
        }
        .task(id: monitor.dataVersion) { await loadPolicySources() }
        .onAppear {
            if let request = nav.ruleRequest {
                sheet = .editor(request.rule, isNew: true)
                nav.ruleRequest = nil
            }
            takeTemplateRequest()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    /// A template chosen from a table row on another screen. It arrives as a request rather than as saved rules so
    /// that what lands is what was looked at.
    private func takeTemplateRequest() {
        guard let pending = templates.pending else { return }
        sheet = .library(pending.template.id, pending.subject)
        templates.pending = nil
    }

    private func handle(_ destination: PolicyDestination) {
        nav.rulesTab = .rules
        switch destination {
        case .rule(let id):
            if let rule = store.rules.first(where: { $0.id == id }) { sheet = .editor(rule, isNew: false) }
        case .managedPack(let packID):
            focusPolicyID = packID.map { PolicyInventoryID.make(.managedPack, sourceID: $0) } ?? "managed-packs"
            if let packID, let pack = monitor.rulePacks.definitions.first(where: { $0.id == packID }) {
                sheet = .pack(pack, .review)
            }
        case .allowlist(let agentID):
            nav.showAgentPolicy(agentID: agentID, section: .allowlist)
        case .guardrail(let id, let agentID):
            if agentID.isEmpty {
                sheet = .globalGuardrails(id)
            } else {
                nav.showAgentPolicy(agentID: agentID, section: .guardrails, guardrailID: id)
            }
        case .mock(let id):
            nav.showInspectionPolicy(.mocks, policyID: id)
        case .requestRewrite(let id):
            nav.showInspectionPolicy(.requestRewrites, policyID: id)
        case .responseTransform(let id):
            nav.showInspectionPolicy(.responseTransforms, policyID: id)
        }
    }

    private func loadPolicySources() async {
        let since = Date().addingTimeInterval(-30 * 86_400)
        let pageSize = Self.policyEffectPageSize
        let loaded = try? await monitor.read { db in
            (try db.loadPolicies(),
             try db.alerts(limit: 2_000, kind: AnomalyEngine.Kind.allowlistViolation.rawValue),
             try db.exchanges(since: since, limit: pageSize + 1, policyEffectsOnly: true))
        }
        guard let loaded else { return }
        allowlists = loaded.0
        alerts = loaded.1
        exchanges = Array(loaded.2.prefix(pageSize))
        hasMorePolicyEffects = loaded.2.count > pageSize
        policyEffectSince = since
        loadingMorePolicyEffects = false
    }

    private func loadMorePolicyEffects() async {
        guard hasMorePolicyEffects, !loadingMorePolicyEffects else { return }
        loadingMorePolicyEffects = true
        let pageSize = Self.policyEffectPageSize
        let since = policyEffectSince
        guard let cursor = exchanges.last, let cursorID = cursor.id else {
            hasMorePolicyEffects = false
            loadingMorePolicyEffects = false
            return
        }
        guard let page = try? await monitor.read({ db in
            try db.exchanges(since: since, limit: pageSize + 1,
                             before: cursor.started, beforeID: cursorID, policyEffectsOnly: true)
        }) else {
            loadingMorePolicyEffects = false
            return
        }
        let known = Set(exchanges.compactMap(\.id))
        exchanges.append(contentsOf: page.prefix(pageSize).filter { exchange in
            guard let id = exchange.id else { return true }
            return !known.contains(id)
        })
        hasMorePolicyEffects = page.count > pageSize
        loadingMorePolicyEffects = false
    }

    private var inventoryItems: [PolicyInventoryItem] {
        #if APP_STORE
        let attributionReady = monitor.inspection.attributionReady
        #else
        let attributionReady = true
        #endif
        return PolicyInventoryBuilder.build(rules: store.rules, allowlists: allowlists,
                                     packs: monitor.rulePacks.definitions,
                                     unavailablePacks: monitor.rulePacks.unavailableReviewConfigurations,
                                     packConfiguration: { monitor.rulePacks.configuration(for: $0) },
                                     packNeedsReview: monitor.rulePacks.needsReview,
                                     packStatus: monitor.rulePacks.status,
                                     guardrails: monitor.guardrails.guardrails,
                                     mocks: monitor.inspection.mockRules,
                                     rewrites: monitor.inspection.rewriteRules,
                                     transforms: monitor.inspection.responseTransformRules,
                                     extensionRunning: monitor.canBlock, canBlock: monitor.canBlock,
                                     inspectionEnabled: monitor.inspection.enabled,
                                     inspectionRunning: monitor.inspection.running,
                                     inspectionTrusted: monitor.inspection.trusted,
                                     inspectionAttributionReady: attributionReady,
                                     rulesPaused: store.isPaused, now: now)
    }

    private var subtitle: String {
        if store.isPaused, let until = store.pausedUntil {
            return L("Paused until %@", until.formatted(date: .omitted, time: .shortened))
        }
        let effective = inventoryItems.filter { $0.effect.isEffective }.count
        guard !inventoryItems.isEmpty else { return "" }
        return effective == 0
            ? L("%lld policies · none currently effective", inventoryItems.count)
            : L("%1$lld policies · %2$lld currently effective", inventoryItems.count, effective)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("", selection: $nav.rulesTab) {
                ForEach(RulesTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
        }
        ToolbarItemGroup {
            pauseControl
            if nav.rulesTab == .rules {
                Button {
                    sheet = .library(nil, RuleTemplate.Subject())
                } label: {
                    Label(L("Templates"), systemImage: "square.grid.2x2")
                }
                .help(L("Rules worth having, grouped by what they are for, with the hosts already written out"))
                Button {
                    sheet = .editor(Rule(), isNew: true)
                } label: {
                    Label(L("Add Rule"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help(L("Write a rule: an app, an agent, a destination or a URL, blocked or allowed"))
            }
        }
    }

    /// The escape hatch. A strict rule is only liveable if there is an obvious way to stand it down for a minute,
    /// and an escape hatch that has to be found in Settings isn't one.
    @ViewBuilder
    private var pauseControl: some View {
        if store.isPaused, let until = store.pausedUntil {
            Button {
                store.resume()
            } label: {
                Label(L("Paused until %@", until.formatted(date: .omitted, time: .shortened)),
                      systemImage: "play.circle.fill")
            }
            .tint(FL.warning)
            .help(L("Nothing is being refused. Click to start again now."))
        } else {
            Menu {
                Button(L("10 minutes")) { store.pause(for: 600) }
                Button(L("1 hour")) { store.pause(for: 3600) }
                Button(L("Until I resume")) { store.pause(for: 60 * 60 * 24 * 365) }
            } label: {
                Label(L("Pause Blocking"), systemImage: "pause.circle")
            }
            .help(L("Stand every rule down for a while, without deleting anything"))
        }
    }

    /// What the rules as a set can't do here. Per-rule limitations sit on the rows; this is the one worth saying
    /// once, because it applies to almost everything in the list.
    private var engineWarning: String? {
        let blind = RuleBook.unenforceable(store.rules, extensionRunning: monitor.mode == .networkExtension,
                                           inspecting: monitor.inspection.enabled)
        guard !blind.isEmpty else { return nil }
        // One key per sentence, singular and plural apart: a count spliced into the middle of a translated
        // sentence is a sentence no translator can shape.
        if monitor.mode != .networkExtension && blind.contains(where: { $0.engine == .flow }) {
            return blind.count == 1
                ? L("One rule is being watched but not carried out. Only the Network Extension sits in the data path and can refuse a connection; the nettop sampler counts traffic after the fact. Select the Network Extension in Sources › Collector to enforce these rules.")
                : L("%lld rules are being watched but not carried out. Only the Network Extension sits in the data path and can refuse a connection; the nettop sampler counts traffic after the fact. Select the Network Extension in Sources › Collector to enforce these rules.", blind.count)
        }
        return blind.count == 1
            ? L("One rule is being watched but not carried out — a rule that names a path can only be matched by HTTPS inspection, and it is off.")
            : L("%lld rules are being watched but not carried out — a rule that names a path can only be matched by HTTPS inspection, and it is off.", blind.count)
    }

    // MARK: The list

    /// Rules that would decide something if a connection arrived this second, and the ones that wouldn't. A rule
    /// outside its hours, switched off, expired or already spent is still a rule someone wrote — it belongs on the
    /// screen, just not among the ones doing the work. The global pause deliberately doesn't move anything: it is
    /// said once in the banner, and shuffling the whole list for ten minutes would lose people's place.
    private var inForce: [Rule] {
        NetworkRuleGrouping.inForce(store.rules, at: now, session: RuleStore.session)
    }

    private var resting: [Rule] {
        NetworkRuleGrouping.resting(store.rules, at: now, session: RuleStore.session)
    }

    private var inventory: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    inventoryIntroduction
                    if inventoryItems.isEmpty { empty }
                    ForEach(PolicyInventoryKind.allCases, id: \.self) { kind in
                        let items = inventoryItems.filter { $0.kind == kind }
                        if !items.isEmpty {
                            if kind == .networkRule { networkRuleSection(items: items) }
                            else { inventorySection(kind, items: items) }
                        }
                    }
                }
                .padding(Measure.gutter)
            }
            .onChange(of: focusPolicyID) { _, target in
                guard let target else { return }
                Motion.perform(Motion.control, reduceMotion: reduceMotion) {
                    scroll.scrollTo(target, anchor: .center)
                }
                focusPolicyID = nil
            }
            .onAppear {
                guard let target = focusPolicyID else { return }
                DispatchQueue.main.async {
                    scroll.scrollTo(target, anchor: .center)
                    focusPolicyID = nil
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { banner }
    }

    private var inventoryIntroduction: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Everything Flowlight can apply")).font(.headline)
            Text(PolicyInventoryCapabilities.current.inspectionPolicies
                 ? L("Network decisions, agent limits, managed destination lists, and inspection policies live here. Each policy still opens in the editor that owns its behavior and consent.")
                 : L("Network decisions, agent limits, and managed destination lists live here. Each policy still opens in the editor that owns its behavior and consent."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func networkRuleSection(items: [PolicyInventoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: PolicyInventoryKind.networkRule.symbol)
                    .font(.caption).foregroundStyle(.tertiary)
                Text(PolicyInventoryKind.networkRule.sectionTitle)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
            }
            ruleGroup(L("In force"), rules: inForce)
            ruleGroup(L("Not in force"), rules: resting)
        }
    }

    @ViewBuilder
    private func ruleGroup(_ title: String, rules: [Rule]) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                heading(title)
                VStack(spacing: 7) {
                    ForEach(rules) { rule in
                        row(rule)
                            .id(PolicyInventoryID.make(.networkRule,
                                                       sourceID: rule.id.uuidString.lowercased()))
                    }
                }
            }
        }
    }

    private func inventorySection(_ kind: PolicyInventoryKind, items: [PolicyInventoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol).font(.caption).foregroundStyle(.tertiary)
                Text(kind.sectionTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(items.count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                if kind == .managedPack { packCatalogControls }
            }
            .id(kind == .managedPack ? "managed-packs" : "section-\(kind.rawValue)")
            if kind == .managedPack { packCatalogProvenance }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 40) }
                    inventoryRow(item).id(item.id)
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func inventoryRow(_ item: PolicyInventoryItem) -> some View {
        if item.kind == .networkRule,
           let rule = store.rules.first(where: { $0.id.uuidString.caseInsensitiveCompare(item.sourceID) == .orderedSame }) {
            row(rule)
        } else if item.kind == .managedPack,
                  let pack = monitor.rulePacks.definitions.first(where: { $0.id == item.sourceID }) {
            packRow(pack)
        } else if item.kind == .managedPack,
                  let configuration = monitor.rulePacks.unavailableReviewConfigurations.first(where: { $0.packID == item.sourceID }) {
            unavailablePackRow(configuration)
        } else {
            Button { handle(item.destination) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.kind.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.isEnabled ? FL.accent : .secondary)
                        .frame(width: 26, height: 26)
                        .background((item.isEnabled ? FL.accent : Color.secondary).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let reason = item.reason {
                            Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(item.effect.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(policyStatusTint(item.effect))
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 3)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func policyStatusTint(_ effect: PolicyEffectState) -> AnyShapeStyle {
        switch effect {
        case .effective: return AnyShapeStyle(FL.good)
        case .httpOnly, .reportingOnly, .watchingOnly, .waiting, .needsReview: return AnyShapeStyle(FL.warning)
        case .failed, .unavailable: return AnyShapeStyle(FL.critical)
        case .off: return AnyShapeStyle(.tertiary)
        }
    }

    private func packRow(_ pack: RulePackDefinition) -> some View {
        let configuration = monitor.rulePacks.configuration(for: pack.id)
        let item = inventoryItems.first { $0.kind == .managedPack && $0.sourceID == pack.id }
        let blocks = monitor.rulePacks.events(for: pack.id).reduce(0) { $0 + $1.count }
        let exceptions = monitor.rulePacks.overrides(for: pack.id).count
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(configuration.enabled ? FL.critical : .secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(L(pack.manifest.titleKey)).font(.callout.weight(.medium))
                Text(L("%lld destinations · %@", pack.entries.count,
                       configuration.scope == .allApps ? L("every app") : L("%lld selected apps", configuration.apps.count)))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if blocks > 0 { Text(L("%lld blocked", blocks)).foregroundStyle(FL.critical) }
                    if exceptions > 0 { Text(L("%lld exceptions", exceptions)).foregroundStyle(FL.good) }
                }
                .font(.caption2.monospacedDigit())
                if let reason = item?.reason {
                    Text(reason).font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L(pack.manifest.caveatKey)).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(monitor.rulePackCatalog.isDownloadedUpdate(pack)
                     ? L("Official · Verified official update · pack v%@ · %@", pack.manifest.version, pack.manifest.license)
                     : L("Official · Bundled baseline · pack v%@ · %@", pack.manifest.version, pack.manifest.license))
                    .font(.caption2).foregroundStyle(.tertiary)
                if let error = packSaveErrors[pack.id] {
                    Text(error).font(.caption).foregroundStyle(FL.critical)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let item {
                    Text(item.effect.title).font(.caption.weight(.medium))
                        .foregroundStyle(policyStatusTint(item.effect))
                }
                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(get: { configuration.enabled }, set: { enabled in
                        if enabled {
                            sheet = .pack(pack, .activate)
                        } else {
                            var changed = configuration
                            changed.enabled = false
                            packSaveErrors[pack.id] = nil
                            monitor.rulePacks.save(changed) { success in
                                if !success { packSaveErrors[pack.id] = monitor.rulePacks.failureMessage ?? L("Failed: %@", L("Save")) }
                            }
                        }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Button(L("Review…")) { sheet = .pack(pack, .review) }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func unavailablePackRow(_ configuration: RulePackConfiguration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.caption.weight(.semibold)).foregroundStyle(FL.warning)
                .frame(width: 26, height: 26).background(FL.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.packID).font(.callout.weight(.medium))
                Text(L("This previously enabled official pack is no longer in the catalog. Blocking stopped automatically."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = packSaveErrors[configuration.packID] {
                    Text(error).font(.caption).foregroundStyle(FL.critical)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(PolicyEffectState.unavailable.title).font(.caption.weight(.medium))
                    .foregroundStyle(policyStatusTint(.unavailable))
                Button(L("Acknowledge")) {
                    packSaveErrors[configuration.packID] = nil
                    monitor.rulePacks.acknowledgeUnavailableReview(configuration.packID) { success in
                        if !success {
                            packSaveErrors[configuration.packID] = monitor.rulePacks.failureMessage ?? L("Failed: %@", L("Save"))
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var packCatalogProvenance: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(L("Source")) {
                    Text(RulePackCatalogVerifier.sourceURL).font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let receipt = monitor.rulePackCatalog.receipt {
                    LabeledContent(L("Publisher")) {
                        Text(L("Flowlight · signer %@", receipt.signerKeyID))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    LabeledContent(L("Catalog")) {
                        Text(L("Sequence %1$lld · digest %2$@", receipt.sequence, String(receipt.digest.prefix(12))))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let success = monitor.rulePackCatalog.catalogState.update.lastSuccess {
                    LabeledContent(L("Last verified")) {
                        Text(success.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if monitor.rulePackCatalog.automaticRefresh,
                   let next = monitor.rulePackCatalog.catalogState.update.nextEligibleAttempt {
                    LabeledContent(L("Next check")) {
                        Text(next.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 5)
        } label: {
            Label(L("Official catalog details"), systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
    }

    private var packCatalogControls: some View {
        HStack(spacing: 8) {
            Text(packCatalogStatus).font(.caption2).foregroundStyle(.tertiary)
            Menu {
                Toggle(L("Automatic updates"), isOn: Binding(
                    get: { monitor.rulePackCatalog.automaticRefresh },
                    set: { enabled in Task { await monitor.rulePackCatalog.setAutomaticRefresh(enabled) } }
                ))
                Button(L("Check Now")) { Task { await monitor.rulePackCatalog.checkNow() } }
                    .disabled(monitor.rulePackCatalog.status == .checking)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Official pack updates"))
        }
    }

    private var packCatalogStatus: String {
        switch monitor.rulePackCatalog.status {
        case .idle: return L("Not checked")
        case .checking: return L("Checking…")
        case .current: return L("Verified")
        case .stale: return L("Stale")
        case .recovery: return L("Recovery required")
        case .failed: return L("Check failed")
        }
    }

    private func row(_ rule: Rule) -> some View {
        let policy = inventoryItems.first { $0.kind == .networkRule && $0.sourceID == rule.id.uuidString.lowercased() }
        return RuleRow(rule: rule, store: store, now: now,
                extensionRunning: monitor.canBlock,
                inspecting: monitor.inspection.enabled && monitor.inspection.running,
                events: store.events(for: rule).count,
                effect: policy?.effect ?? .off, effectReason: policy?.reason) {
            sheet = .editor(rule, isNew: false)
        }
        // A rule that has just been written, or has just crossed between in force and not, is a change of state
        // worth marking. Nothing moves that hasn't changed.
        .entrance()
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    /// The one thing that outranks every row: everything is standing down, or most of it isn't being carried out.
    /// The pause comes first because it explains the rest.
    @ViewBuilder
    private var banner: some View {
        if store.isPaused, let until = store.pausedUntil {
            HStack(spacing: 8) {
                Image(systemName: "pause.circle.fill").foregroundStyle(FL.warning)
                Text(L("Nothing is being refused until %@.", until.formatted(date: .omitted, time: .shortened)))
                    .font(.callout)
                Spacer(minLength: 8)
                Button(L("Resume now")) { store.resume() }.buttonStyle(.link)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        } else if let warning = engineWarning {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye").foregroundStyle(FL.warning)
                Text(warning).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(L("No rules yet"), systemImage: "hand.raised")
        } description: {
            Text(L("A rule names something — an app, an agent, a destination, or a URL — and says block or allow. Right-click any row in Live, History, AI Agents or Inspect to write one about what you're looking at, or start from the library — it already knows which hosts a package install reaches, and which ones a file leaves by."))
        } actions: {
            Button(L("Browse Templates…")) { sheet = .library(nil, RuleTemplate.Subject()) }
            Button(L("Write One…")) { sheet = .editor(Rule(), isNew: true) }
        }
    }

    // MARK: The violations feed

    private var activityFeed: some View {
        Group {
            if policyActivity.isEmpty && monitor.rulePacks.deliveryStats.droppedHits == 0 {
                ContentUnavailableView {
                    Label(L("Nothing yet"), systemImage: "list.bullet.rectangle")
                } description: {
                    Text(PolicyInventoryCapabilities.current.inspectionPolicies
                         ? L("Blocks, exceptions, allowlist violations, guardrails, mocks, and request or response changes appear here without changing their original records.")
                         : L("Network blocks, exceptions, managed-pack matches, and allowlist violations appear here without changing their original records."))
                }
            } else {
                feed
            }
        }
    }

    /// The existing sources, adapted into one read-only chronology. The original records remain the source of truth;
    /// this list only gives their effects a shared vocabulary.
    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if monitor.rulePacks.deliveryStats.droppedHits > 0 {
                    Label(L("%lld managed-pack decisions were omitted from activity because the extension's bounded queue was full.",
                            monitor.rulePacks.deliveryStats.droppedHits), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(FL.warning)
                        .padding(10).background(FL.warning.opacity(0.1),
                                                in: RoundedRectangle(cornerRadius: Radius.chip))
                }
                ForEach(activityDays) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        heading(day.title)
                        VStack(spacing: 0) {
                            ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                                if index > 0 { Divider().padding(.leading, 38) }
                                activityRow(event)
                            }
                        }
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if hasMorePolicyEffects {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear { Task { await loadMorePolicyEffects() } }
                }
            }
            .padding(Measure.gutter)
        }
    }

    @ViewBuilder
    private func activityRow(_ event: PolicyActivityItem) -> some View {
        switch event.source {
        case .rule(let record):
            EventRow(event: record, rule: event.title) { showPolicy(for: event) }
        case .managedPack(let record):
            RulePackEventRow(event: record)
        case .generic:
            PolicyActivityRow(event: event) { showPolicy(for: event) }
        }
    }

    private func showPolicy(for event: PolicyActivityItem) {
        guard let policyID = event.policyID,
              let item = inventoryItems.first(where: { $0.id == policyID }) else { return }
        handle(item.destination)
    }

    private struct ActivityDay: Identifiable {
        let id: Date
        let title: String
        let events: [PolicyActivityItem]
    }

    private var policyActivity: [PolicyActivityItem] {
        PolicyActivityBuilder.build(ruleEvents: store.events, packEvents: monitor.rulePacks.events,
                                    alerts: alerts, exchanges: exchanges, rules: store.rules,
                                    guardrails: monitor.guardrails.guardrails, packs: monitor.rulePacks.definitions,
                                    mocks: monitor.inspection.mockRules, rewrites: monitor.inspection.rewriteRules,
                                    transforms: monitor.inspection.responseTransformRules,
                                    policies: Array(allowlists.values))
    }

    private var activityDays: [ActivityDay] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: policyActivity) { calendar.startOfDay(for: $0.timestamp) }
        return byDay.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? L("Today")
                : calendar.isDateInYesterday(day) ? L("Yesterday")
                : day.formatted(date: .abbreviated, time: .omitted)
            return ActivityDay(id: day, title: title, events: byDay[day] ?? [])
        }
    }
}

private struct GlobalGuardrailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: GuardrailStore
    let focus: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Agent guardrails")).font(.title2.bold())
                    Text(L("Every agent")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            GuardrailsPane(store: store, agentKey: "", agentName: L("Every agent"), declared: [], servers: [],
                           focus: focus)
        }
        .padding(20)
        .frame(width: 680, height: 640)
    }
}

private struct PolicyActivityRow: View {
    let event: PolicyActivityItem
    let showPolicy: () -> Void

    var body: some View {
        Button(action: showPolicy) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.caption).foregroundStyle(tint).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(effectTitle).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(event.policyID == nil)
    }

    private var effectTitle: String {
        switch event.effect {
        case .blocked: return L("Blocked connection or request")
        case .allowed: return L("Allowed by an exception")
        case .packBlocked: return L("Blocked by a managed pack")
        case .allowlistViolation: return L("Outside an agent allowlist")
        case .guardrailApplied: return L("Capability removed by a guardrail")
        case .mocked: return L("Answered by a mock")
        case .requestRewritten: return L("Request changed before sending")
        case .responseTransformed: return L("Response changed before delivery")
        }
    }

    private var symbol: String {
        switch event.effect {
        case .allowed: return "checkmark.shield.fill"
        case .mocked: return "wand.and.stars"
        case .requestRewritten: return "slider.horizontal.3"
        case .responseTransformed: return "arrow.left.arrow.right"
        case .guardrailApplied: return "wrench.and.screwdriver.fill"
        case .allowlistViolation: return "checklist.unchecked"
        case .blocked, .packBlocked: return "hand.raised.fill"
        }
    }

    private var tint: Color {
        event.effect == .allowed ? FL.good
            : (event.effect == .mocked || event.effect == .requestRewritten || event.effect == .responseTransformed
               ? FL.tool : FL.critical)
    }
}

/// One rule in the list: what it says, when it applies, what it has done, and what it can't do here.
///
/// The row is read top down and the type sizes say so — the subject and the verb first, the technical form of it
/// underneath in monospace, and the bookkeeping last. Everything a rule can't do here is the exception to that:
/// it gets its own strip, because a rule that isn't biting is the thing someone came to the screen to find out.
private struct RuleRow: View {
    let rule: Rule
    let store: RuleStore
    let now: Date
    let extensionRunning: Bool
    let inspecting: Bool
    let events: Int
    let effect: PolicyEffectState
    let effectReason: String?
    let edit: () -> Void

    private var limitation: String? {
        guard rule.enabled else { return nil }
        return RuleWords.limitation(rule, extensionRunning: extensionRunning, inspecting: inspecting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                glyph
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        headline.lineLimit(2)
                        if rule.origin != .typed {
                            Text(originLabel).font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    // Only worth a line of its own where the headline is a name someone chose, which hides it.
                    if !rule.name.isEmpty {
                        Text(subject).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    meta
                }
                Spacer(minLength: 8)
                Text(effect.title).font(.caption.weight(.medium)).foregroundStyle(effectTint)
                    .padding(.top, 3)
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule, $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .accessibilityLabel(L("Enable %@", RuleWords.title(rule)))
                    .padding(.top, 2)
                Menu {
                    Button(L("Edit…"), action: edit)
                    if rule.hits > 0 { Button(L("Reset Count")) { store.resetHits(rule) } }
                    Divider()
                    Button(L("Delete"), role: .destructive) { store.delete(rule) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 16)
                .accessibilityLabel(L("More for %@", RuleWords.title(rule)))
            }
            if let limitation {
                note(limitation, icon: "eye", tint: FL.warning)
            } else if let effectReason, rule.isUsable {
                note(effectReason, icon: effect == .off ? "power" : "clock", tint: .secondary)
            }
            if !rule.isUsable {
                note(L("Used up — a one-off allowance, already spent."), icon: "checkmark.circle", tint: .secondary)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .contextMenu {
            Button(L("Edit…"), action: edit)
            if rule.hits > 0 { Button(L("Reset Count")) { store.resetHits(rule) } }
            Divider()
            Button(L("Delete"), role: .destructive) { store.delete(rule) }
        }
    }

    private var effectTint: AnyShapeStyle {
        switch effect {
        case .effective: return AnyShapeStyle(FL.good)
        case .httpOnly, .reportingOnly, .watchingOnly, .waiting, .needsReview: return AnyShapeStyle(FL.warning)
        case .failed, .unavailable: return AnyShapeStyle(FL.critical)
        case .off: return AnyShapeStyle(.tertiary)
        }
    }

    /// The verb, as a symbol. A rule that is only being watched says so here as well as in the strip below, because
    /// this is the mark the eye lands on first and a red hand over a rule that refuses nothing would be a lie.
    private var glyph: some View {
        let tint: Color = !rule.enabled ? .secondary
            : limitation != nil ? FL.warning
            : rule.action == .block ? FL.critical : FL.good
        let symbol = limitation != nil && rule.enabled ? "eye.fill"
            : rule.action == .block ? "hand.raised.fill" : "checkmark.shield.fill"
        return Image(systemName: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(rule.action == .block ? L("Blocks") : L("Allows"))
    }

    /// The name if there is one, otherwise the rule read back as a sentence with the parts it names set in
    /// monospace — the same shape the editor shows while it is being written.
    private var headline: Text {
        if !rule.name.isEmpty { return Text(rule.name).font(.body.weight(.medium)) }
        // One key for the whole line, so a translator can put the app and the destination where their language
        // wants them; both are handed back in monospace by `RuleWords.sentence`.
        let format = rule.action == .block ? L("Block %1$@ reaching %2$@") : L("Allow %1$@ reaching %2$@")
        return RuleWords.sentence(format, [code(rule.app.isEmpty ? L("any app") : rule.app), code(target)],
                                  plain: { Text($0).font(.body.weight(.medium)) })
    }

    private func code(_ string: String) -> Text {
        Text(string).font(.body.weight(.medium).monospaced())
    }

    private var target: String {
        var text = rule.destination.isEmpty ? L("anywhere") : rule.destination
        if !rule.path.isEmpty { text += rule.path }
        if !rule.method.isEmpty { text = "\(rule.method.uppercased()) \(text)" }
        return text
    }

    private var subject: String {
        "\(rule.app.isEmpty ? L("any app") : rule.app) → \(target)"
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
            Text(RuleWords.schedule(rule.schedule, at: now, session: RuleStore.session))
                .font(.caption).foregroundStyle(.secondary)
            if rule.hits > 0 {
                Text("·").font(.caption).foregroundStyle(.quaternary)
                Text(rule.hits == 1 ? L("%lld time", rule.hits) : L("%lld times", rule.hits))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help(events == 1 ? L("1 decision kept in the feed") : L("%lld decisions kept in the feed", events))
                if let last = rule.lastHit {
                    Text("·").font(.caption).foregroundStyle(.quaternary)
                    Text(L("last %@", last.formatted(.relative(presentation: .named))))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            } else if rule.enabled {
                Text("·").font(.caption).foregroundStyle(.quaternary)
                Text(L("never yet")).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.leading, 38)
    }

    private var originLabel: String {
        switch rule.origin {
        case .typed: return L("typed")
        case .preset: return L("preset")
        case .alert: return L("from an alert")
        case .allowOnce: return L("allowed once")
        }
    }
}

/// One decision, in the feed. The destination is what someone scans for, so it leads and it is set in monospace;
/// who asked and which rule answered sit under it, and the clock sits where a clock belongs.
private struct EventRow: View {
    let event: RuleEventRecord
    let rule: String
    let showRule: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.action == .block ? "hand.raised.fill" : "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(event.action == .block ? FL.critical : FL.good)
                .frame(width: 14)
                .padding(.top, 2)
                .help(event.action == .block ? L("Refused") : L("Allowed by an exception"))
            VStack(alignment: .leading, spacing: 2) {
                Text(destination).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(who).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").font(.caption).foregroundStyle(.quaternary)
                    Text(rule).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(event.engine == .flow ? L("Connection") : L("Request"))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .help(event.engine == .flow
                          ? L("Refused by the Network Extension, before the connection was made")
                          : L("Refused by HTTPS inspection, which answered the request itself"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Show the Rule…"), action: showRule)
            Button(L("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "\(event.timestamp.formatted(date: .abbreviated, time: .standard))  "
                    + "\(event.action == .block ? L("blocked") : L("allowed"))  \(who)  \(destination)  \(rule)",
                    forType: .string)
            }
        }
    }

    private var destination: String {
        event.path.isEmpty ? "\(event.destination):\(event.port)"
                           : "\(event.method) \(event.destination)\(event.path)"
    }

    private var who: String {
        event.agentName.isEmpty || event.agentName == event.appName
            ? event.appName : "\(event.agentName) › \(event.appName)"
    }
}

/// "Block this", wherever traffic is shown. Every table offers it, and every one of them writes the same rule and
/// lands in the same editor — a rule that took effect out of sight would be a rule nobody could find again.
///
/// The template submenu keeps the same promise three different ways, because a template can be bigger than one
/// rule and the editor only holds one. Which way is used is decided by the template and said in the menu before
/// the click, in the section heading and again in the macOS ellipsis.
struct RuleMenuItems: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var monitor: TrafficMonitor
    var app: (bundleID: String, name: String)?
    var host: String?

    private var subject: RuleTemplate.Subject {
        RuleTemplate.Subject(app: app?.bundleID ?? "", appName: app?.name ?? "", destination: host ?? "")
    }

    var body: some View {
        if let app, !app.bundleID.isEmpty {
            // No name is stored. A generated one would be written into the rule and shown ever after in the
            // language the interface happened to be in that day; the list composes the same sentence from the
            // rule's own fields instead, so it follows the picker. A name someone types is their words and is
            // kept exactly as typed.
            Menu(L("Block %@…", app.name)) {
                Button(L("Everywhere")) { write(RuleStore.block(app: app.bundleID)) }
                if let host {
                    Button(L("From reaching %@", host)) {
                        write(RuleStore.block(app: app.bundleID, destination: host))
                    }
                }
                Button(L("For the next hour")) {
                    write(RuleStore.block(app: app.bundleID,
                                          schedule: .expiring(in: 3600)))
                }
                Button(L("Until Flowlight quits")) {
                    write(RuleStore.block(app: app.bundleID,
                                          schedule: .thisSession(RuleStore.session)))
                }
            }
        }
        if let host, !host.isEmpty {
            Menu(L("Block %@…", host)) {
                Button(L("For every app")) {
                    write(RuleStore.block(destination: host))
                }
                Button(L("For the next hour")) {
                    write(RuleStore.block(destination: host,
                                          schedule: .expiring(in: 3600)))
                }
            }
        }
        templateMenu
    }

    /// The library, filtered down to what this row can fill in, grouped the way the library groups it. Each
    /// heading says what clicking will do, because a menu that changes the machine and a menu that opens a window
    /// look identical until afterwards.
    @ViewBuilder
    private var templateMenu: some View {
        let applicable = RuleTemplate.applicable(to: subject)
        if !applicable.isEmpty {
            Menu(L("Apply a Template")) {
                ForEach(RuleTemplate.Category.allCases) { category in
                    let found = applicable.filter { $0.category == category }
                    if !found.isEmpty {
                        Section(heading(category, for: found)) {
                            ForEach(found) { template in
                                let now = template.arrival(for: subject) == .now
                                Button(now ? template.title : "\(template.title)…") { apply(template) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func heading(_ category: RuleTemplate.Category, for found: [RuleTemplate]) -> String {
        let immediate = found.filter { $0.arrival(for: subject) == .now }.count
        if immediate == found.count { return L("%@ · in force at once", category.title) }
        if immediate == 0 { return L("%@ · shown first", category.title) }
        return category.title
    }

    private func apply(_ template: RuleTemplate) {
        switch template.arrival(for: subject) {
        case .now:
            // The one place a rule is saved without being read back first. It is allowed here because the menu
            // said so, because it is a single rule, and because it undoes itself — and the screen deliberately
            // stays where it is, since the reason to block a destination for an hour is to keep watching the
            // table you are already looking at.
            for rule in template.rules(for: subject) { monitor.rules.save(rule) }
        case .editor:
            if let rule = template.rules(for: subject).first { nav.writeRule(rule) }
        case .list:
            RuleTemplateRequests.shared.open(template, for: subject)
            nav.showRules()
        }
    }

    private func write(_ rule: Rule) { nav.writeRule(rule) }
}

/// The rule library, as a sheet.
///
/// The screen is a list of offers, and an offer nobody can check is an offer nobody should accept — so a card
/// opens onto the whole of what it would write: every host, every schedule, and the sentence about what it costs.
/// Nothing is added from a closed card.
struct RuleTemplateLibrary: View {
    /// A template to open on, when the sheet was raised from a table row rather than from the toolbar.
    var focus: RuleTemplate.ID?
    var subject: RuleTemplate.Subject
    let add: ([Rule]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var open: RuleTemplate.ID?
    @State private var app = ""
    @State private var destination = ""
    @State private var added: Set<RuleTemplate.ID> = []
    @State private var installed: [InstalledApps.App] = []

    /// The subject as the cards see it. The readable name is looked up rather than stored, so typing over the app
    /// can't leave a rule named after the one that was there before.
    private var filled: RuleTemplate.Subject {
        RuleTemplate.Subject(app: app, appName: name(of: app), destination: destination)
    }

    private func name(of bundleID: String) -> String {
        if bundleID.caseInsensitiveCompare(subject.app) == .orderedSame, !subject.appName.isEmpty {
            return subject.appName
        }
        return installed.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }?.name ?? bundleID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(RuleTemplate.Category.allCases) { category in
                            section(category)
                        }
                    }
                    .padding(Measure.gutter)
                }
                .onAppear {
                    open = focus
                    app = subject.app
                    destination = subject.destination
                    if let focus { scroll.scrollTo(focus, anchor: .top) }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Measure.gutter)
        }
        .frame(width: Measure.prose)
        .frame(minHeight: 560)
        .task {
            installed = await Task.detached(priority: .userInitiated) { InstalledApps.all() }.value
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Templates")).font(.title3.weight(.semibold))
            Text(L("Each one writes ordinary rules into the list, where they can be read, switched off or deleted like anything else. Refusing a connection is the Network Extension's job, so with the nettop sampler selected in Sources › Collector these are watched rather than carried out."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Measure.gutter)
    }

    private func section(_ category: RuleTemplate.Category) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: category.symbol).font(.caption).foregroundStyle(.tertiary)
                Text(category.title).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
            Text(category.summary).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(RuleTemplate.inCategory(category)) { template in
                card(template).id(template.id)
            }
        }
    }

    private func card(_ template: RuleTemplate) -> some View {
        let isOpen = open == template.id
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                open = isOpen ? nil : template.id
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(template.title).font(.body.weight(.medium))
                        Text(template.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(countLabel(template)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { openCard(template) }
        }
        .padding(12)
        .background(.quaternary.opacity(isOpen ? 0.5 : 0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    /// What an open card shows: the blank it still needs, the cost of switching it on, and the rules themselves.
    @ViewBuilder
    private func openCard(_ template: RuleTemplate) -> some View {
        let rules = template.rules(for: filled)
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if template.needs == .app || template.needs == .both {
                appField
            } else if template.scopesToApp {
                appField
                Text(L("Optional. Left empty this applies to everything on the Mac; naming an app narrows it to that app and the tools it started."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if template.needs == .destination || template.needs == .both {
                TextField(L("Destination"), text: $destination,
                          prompt: Text(L("A domain, an IP address, or a range")))
                    .textFieldStyle(.roundedBorder)
            }
            if template.engines(for: filled).contains(.request) {
                note(L("These name an HTTP method, so only HTTPS inspection can carry them out. With it off they sit in the list watching."),
                     icon: "eye", tint: FL.warning)
            }
            if let caveat = template.caveat {
                note(caveat, icon: "exclamationmark.circle", tint: .secondary)
            }
            if rules.isEmpty {
                Text(template.needs == .destination ? L("Name a destination to see what this would write.")
                     : L("Name an app to see what this would write."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ruleList(rules)
            }
            HStack(spacing: 10) {
                Spacer()
                if added.contains(template.id) {
                    Label(L("Added"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(FL.good)
                }
                Button(rules.count > 1 ? L("Add %lld Rules", rules.count) : L("Add Rule")) {
                    add(rules)
                    added.insert(template.id)
                }
                .disabled(rules.isEmpty)
            }
        }
    }

    private var appField: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(L("App"), text: $app, prompt: Text(L("A name, or a bundle identifier")))
                .textFieldStyle(.roundedBorder)
            ForEach(suggestions) { found in
                Button {
                    app = found.bundleID
                } label: {
                    HStack(spacing: 6) {
                        Text(found.name).font(.callout)
                        Text(found.bundleID).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var suggestions: [InstalledApps.App] {
        guard !app.isEmpty,
              !installed.contains(where: { $0.bundleID.caseInsensitiveCompare(app) == .orderedSame }) else { return [] }
        return Array(InstalledApps.search(app, in: installed).prefix(4))
    }

    /// Every rule, written out. Long lists are the whole point of a template, so they aren't truncated — an
    /// abbreviated blocklist is one nobody checked.
    private func ruleList(_ rules: [Rule]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rules) { rule in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "hand.raised.fill").font(.caption2).foregroundStyle(FL.critical.opacity(0.8))
                    Text(subjectLine(rule)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if rule.schedule.kind != .always {
                        Text(RuleWords.schedule(rule.schedule, at: Date(), session: RuleStore.session))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func subjectLine(_ rule: Rule) -> String {
        var target = rule.destination.isEmpty ? L("anywhere") : rule.destination
        if !rule.method.isEmpty { target = "\(rule.method) \(target)" }
        return "\(rule.app.isEmpty ? L("any app") : rule.app) → \(target)"
    }

    private func countLabel(_ template: RuleTemplate) -> String {
        let count = template.ruleCount(for: filled)
        return count == 1 ? L("1 rule") : L("%lld rules", count)
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// How a rule reads, in the language the interface is set to.
///
/// `Rule` itself is compiled into the Network Extension, where `L()` doesn't exist, so the sentences it can build
/// — its title, its schedule, what stops it being carried out — are English and stay English: the extension logs
/// them and reports them over IPC. The interface asks here instead. The decisions are still the model's; only the
/// words are made here, which is what keeps the two from drifting into disagreeing about what a rule does.
enum RuleWords {
    /// The rule read back in one line: a name if someone chose one, otherwise the sentence the model would build.
    static func title(_ rule: Rule) -> String {
        if !rule.name.isEmpty { return rule.name }
        let who = rule.app.isEmpty ? L("anything") : rule.app
        var where_ = rule.destination.isEmpty ? L("anywhere") : rule.destination
        if !rule.path.isEmpty { where_ += rule.path }
        if !rule.method.isEmpty { where_ = "\(rule.method.uppercased()) \(where_)" }
        return rule.action == .block ? L("Block %1$@ → %2$@", who, where_) : L("Allow %1$@ → %2$@", who, where_)
    }

    /// When the rule applies, as a phrase: the same answer `Rule.Schedule.describe` gives, in the chosen language.
    static func schedule(_ schedule: Rule.Schedule, at now: Date = Date(), session current: String = "",
                         calendar: Calendar = .current) -> String {
        switch schedule.kind {
        case .always: return L("Always")
        case .until:
            guard let until = schedule.until else { return L("Always") }
            if now >= until { return L("Expired") }
            let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .wide)
            return L("Until %1$@ (%2$@)", until.formatted(.dateTime.hour().minute()), until.formatted(style))
        case .session:
            return schedule.session == current ? L("Until Flowlight quits") : L("Expired")
        case .window:
            let names = calendar.shortWeekdaySymbols
            let which = schedule.days.isEmpty ? L("Every day")
                : schedule.days.sorted().compactMap { names.indices.contains($0 - 1) ? names[$0 - 1] : nil }
                    .joined(separator: " ")
            // No words of its own: the day names come from the calendar and the clocks are digits.
            return "\(which), \(Rule.Schedule.clock(schedule.start))–\(Rule.Schedule.clock(schedule.end))"
        }
    }

    /// What this rule can't do here, or nil when it is being carried out. Whether there is a limitation at all is
    /// still the model's answer; this only says it in the right language.
    static func limitation(_ rule: Rule, extensionRunning: Bool, inspecting: Bool) -> String? {
        guard rule.limitation(extensionRunning: extensionRunning, inspecting: inspecting) != nil else { return nil }
        switch rule.engine {
        case .flow:
            return L("Watching only — the Network Extension refuses connections, and it isn't running.")
        case .request, .guardrail:
            return L("Watching only — a path can only be matched by HTTPS inspection, and it is off.")
        }
    }

    /// A localized sentence rebuilt as `Text`, with the parts that name something substituted back in.
    ///
    /// The whole sentence is one key — `"Refuse %1$@ reaching %2$@."` — so a translator moves the parts wherever
    /// their language wants them, including past each other. `String(format:)` can't be used to fill it in, because
    /// the parts are styled and it would flatten them to plain characters; so the format is split on its
    /// placeholders instead and the pieces are concatenated as `Text`, which keeps the monospace. A placeholder a
    /// translation asks for but nothing was passed for is dropped, and anything that isn't a string placeholder is
    /// left exactly as written — a mistranslated format loses a word here rather than crashing.
    static func sentence(_ format: String, _ parts: [Text], plain: (String) -> Text = { Text($0) }) -> Text {
        var pieces: [Text] = []
        var literal = ""
        var next = 0
        var rest = Substring(format)

        func flush() {
            guard !literal.isEmpty else { return }
            pieces.append(plain(literal))
            literal = ""
        }

        while let percent = rest.firstIndex(of: "%") {
            literal += rest[rest.startIndex..<percent]
            var cursor = rest.index(after: percent)
            // `%%` is one percent sign, not a placeholder.
            if cursor < rest.endIndex, rest[cursor] == "%" {
                literal.append("%")
                rest = rest[rest.index(after: cursor)...]
                continue
            }
            var digits = ""
            while cursor < rest.endIndex, rest[cursor].isNumber {
                digits.append(rest[cursor])
                cursor = rest.index(after: cursor)
            }
            var which: Int?
            if !digits.isEmpty, cursor < rest.endIndex, rest[cursor] == "$" {
                let at = rest.index(after: cursor)
                if at < rest.endIndex, rest[at] == "@" {
                    which = (Int(digits) ?? 1) - 1
                    cursor = rest.index(after: at)
                }
            } else if digits.isEmpty, cursor < rest.endIndex, rest[cursor] == "@" {
                which = next
                next += 1
                cursor = rest.index(after: cursor)
            }
            guard let index = which else {
                // Something else entirely — keep it, and carry on after the percent sign.
                literal.append("%")
                rest = rest[rest.index(after: percent)...]
                continue
            }
            flush()
            if parts.indices.contains(index) { pieces.append(parts[index]) }
            rest = rest[cursor...]
        }
        literal += rest
        flush()
        return pieces.reduce(Text(verbatim: "")) { $0 + $1 }
    }
}
