import Foundation

enum AgentHealthState: String, CaseIterable, Sendable {
    case healthy = "Healthy"
    case needsSetup = "Needs setup"
    case limitedVisibility = "Limited visibility"
    case attention = "Attention"
    case inactive = "Inactive"
    case notObserved = "Not observed"

    var sortRank: Int {
        switch self {
        case .attention: return 0
        case .needsSetup: return 1
        case .limitedVisibility: return 2
        case .healthy: return 3
        case .notObserved: return 4
        case .inactive: return 5
        }
    }

    var title: String {
        switch self {
        case .healthy: return L("Healthy")
        case .needsSetup: return L("Needs setup")
        case .limitedVisibility: return L("Limited visibility")
        case .attention: return L("Attention")
        case .inactive: return L("Inactive")
        case .notObserved: return L("Not observed")
        }
    }
}

enum AgentRouteState: Sendable, Equatable {
    case notRequested
    case configured
    case observed
    case stale
    case failed
}

/// A deliberately small, injected view of inspection health. Raw errors and diagnoses stay out of the inventory so
/// they cannot expose a service name, path, URL, or other machine-specific detail.
struct AgentInspectionDiagnostics: Sendable, Equatable {
    var available: Bool
    var enabled: Bool
    var running: Bool
    var certificateTrusted: Bool
    var setupFailed: Bool

    static let unavailable = AgentInspectionDiagnostics(
        available: false, enabled: false, running: false, certificateTrusted: false, setupFailed: false
    )
}

struct AgentInventoryPolicyCoverage: Sendable, Equatable {
    var enabled: Bool
    var enforcing: Bool
    var uncoveredDestinations: Int
}

struct AgentInventoryItem: Identifiable, Sendable, Equatable {
    var id: String
    /// Canonical identifier first, followed by every stable bundle/process/name alias used to merge this row.
    var identities: [String]
    /// Exact identifiers that can occur in stored traffic. Display names stay out so a same-named unrelated process
    /// cannot enter History, Inspect, or Focus when this inventory row is selected.
    var trafficIdentities: [String]
    var name: String
    var vendor: String?
    var appPath: String
    var health: AgentHealthState
    var reasons: [String]
    var installed: Bool
    var configured: Bool
    var observed: Bool
    var autoDiscovered: Bool
    var alwaysMonitored: Bool
    var route: AgentRouteState
    var policy: AgentInventoryPolicyCoverage
    var unresolvedAlerts: Int
    var summary: AgentSummary?

    var healthRank: Int { health.sortRank }
    var trafficTotal: Int64 { summary?.total.total ?? 0 }
    var providerNames: String { summary?.providers.map(\.name).joined(separator: ", ") ?? "" }

    /// A testable representation of everything the inventory presents as text. Paths and raw configuration values are
    /// intentionally absent; `appPath` exists only to load the local application icon.
    var displayText: String { ([name, health.rawValue] + reasons).joined(separator: " · ") }
}

struct AgentInventoryInput: Sendable {
    var installedApps: [InstalledApps.App] = []
    var traffic: [AgentSummary] = []
    var workspaces: [AgentWorkspace] = []
    var monitoredAgentNames: Set<String> = []
    /// Keys may be a bundle/process identifier or the catalog display name. Matching is case-insensitive.
    var routes: [String: AgentRouteState] = [:]
    var inspection: AgentInspectionDiagnostics = .unavailable
    var policies: [String: AgentPolicy] = [:]
    var guardrailAgentIDs: [String] = []
    var alerts: [AlertRecord] = []
    var openAlertCounts: [AgentOpenAlertCount] = []
}

/// Builds the complete agent inventory from injected snapshots. It performs no disk, database, process, defaults, or
/// controller access, which keeps both the merge rules and the health explanations deterministic.
enum AgentInventoryBuilder {
    private struct Evidence {
        var known: KnownAgent?
        var durableAgentIDs: Set<String> = []
        var installed: [InstalledApps.App] = []
        var workspaces: [AgentWorkspace] = []
        var summaries: [AgentSummary] = []
    }

    static func build(_ input: AgentInventoryInput) -> [AgentInventoryItem] {
        var evidence: [String: Evidence] = [:]
        let individualAlertCounts = input.alerts.filter { !$0.state.isClosed }.map {
            AgentOpenAlertCount(bundleID: $0.bundleID, appName: $0.appName, count: 1)
        }
        let alertGroups = input.openAlertCounts + individualAlertCounts
        var openAlertGroupIDsByIdentity: [String: Set<Int>] = [:]
        for (index, group) in alertGroups.enumerated() {
            openAlertGroupIDsByIdentity[AgentCatalog.identityComparisonKey(group.bundleID), default: []].insert(index)
            openAlertGroupIDsByIdentity[AgentCatalog.identityComparisonKey(group.appName), default: []].insert(index)
        }
        let monitoredIdentityKeys = Set(input.monitoredAgentNames.map(AgentCatalog.identityComparisonKey))
        var routeStatesByIdentity: [String: [AgentRouteState]] = [:]
        for (identity, state) in input.routes {
            routeStatesByIdentity[AgentCatalog.identityComparisonKey(identity), default: []].append(state)
        }

        for app in input.installedApps {
            guard !AgentCatalog.isBrowser(app.bundleID),
                  let known = AgentCatalog.knownAgent(bundleID: app.bundleID, appName: app.name) else { continue }
            let key = catalogKey(known)
            evidence[key, default: Evidence()].known = known
            evidence[key, default: Evidence()].installed.append(app)
        }

        for workspace in input.workspaces {
            guard let known = catalogAgent(matching: workspace.agent, preferDisplayName: false) else { continue }
            let key = catalogKey(known)
            evidence[key, default: Evidence()].known = known
            evidence[key, default: Evidence()].workspaces.append(workspace)
        }

        // A persisted routing request is inventory evidence too. Keep it visible even before the agent is installed,
        // configured in a discovered workspace, or observed in traffic, so a stale setup cannot disappear from view.
        for name in input.monitoredAgentNames {
            guard let known = catalogAgent(matching: name, preferDisplayName: true) else { continue }
            evidence[catalogKey(known), default: Evidence()].known = known
        }

        // Saved policies and agent-scoped guardrails are durable inventory evidence. Keep their agents visible outside
        // the traffic window so deep links and editors never disappear just because an agent is quiet or no longer
        // installed. Preserve every stored spelling so legacy aliases resolve deterministically.
        let durableAgentIDs = input.policies.values.map(\.agentID) + input.guardrailAgentIDs
        for agentID in durableAgentIDs {
            guard !agentID.isEmpty else { continue }
            let known = catalogAgent(matching: agentID, preferDisplayName: false)
            let key = known.map(catalogKey) ?? "identity:\(AgentCatalog.identityComparisonKey(agentID))"
            evidence[key, default: Evidence()].known = known
            evidence[key, default: Evidence()].durableAgentIDs.insert(agentID)
        }

        for summary in input.traffic {
            guard !AgentCatalog.isBrowser(summary.bundleID), summary.isKnown || !summary.providers.isEmpty else {
                continue
            }
            let known = AgentCatalog.knownAgent(bundleID: summary.bundleID, appName: summary.name)
            let key = known.map(catalogKey) ?? "identity:\(AgentCatalog.identityComparisonKey(summary.bundleID))"
            evidence[key, default: Evidence()].known = known
            evidence[key, default: Evidence()].summaries.append(summary)
        }

        return evidence.values.map {
            item(from: $0, input: input, alertGroups: alertGroups,
                 openAlertGroupIDsByIdentity: openAlertGroupIDsByIdentity,
                 monitoredIdentityKeys: monitoredIdentityKeys,
                 routeStatesByIdentity: routeStatesByIdentity)
        }
            .sorted {
                if $0.healthRank != $1.healthRank { return $0.healthRank < $1.healthRank }
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
            }
    }

    private static func canonicalID(_ agent: KnownAgent) -> String {
        agent.bundleIDs.sorted().first ?? agent.processNames.sorted().first ?? agent.name.lowercased()
    }

    private static func mergedSummary(from evidence: Evidence) -> AgentSummary? {
        guard !evidence.summaries.isEmpty else { return nil }
        let known = evidence.known
        let preferredIDs = (known?.bundleIDs.sorted() ?? [])
            + (known?.processNames.sorted() ?? [])
            + evidence.installed.map(\.bundleID).sorted()
        let rank: (AgentSummary) -> (Int, String) = { summary in
            let index = preferredIDs.firstIndex {
                $0.caseInsensitiveCompare(summary.bundleID) == .orderedSame
            } ?? preferredIDs.count
            return (index, summary.bundleID.lowercased())
        }
        let ordered = evidence.summaries.sorted { rank($0) < rank($1) }
        let canonical = ordered[0]
        var ai = FlowCounters()
        var egress = FlowCounters()
        var providers: [String: FlowCounters] = [:]
        var destinations: [String: AgentDestination] = [:]
        var tools: [String: AgentTool] = [:]
        var alerts = 0

        for summary in ordered {
            ai += summary.ai
            egress += summary.egress
            alerts += summary.alerts
            for provider in summary.providers {
                providers[provider.name, default: FlowCounters()] += provider.counters
            }
            for destination in summary.destinations {
                var merged = destinations[destination.id] ?? destination
                if destinations[destination.id] != nil {
                    merged.counters += destination.counters
                    merged.protocols = Array(Set(merged.protocols + destination.protocols)).sorted()
                    merged.ports = mergedPorts(merged.ports, destination.ports)
                    merged.via = Array(Set(merged.via + destination.via)).sorted()
                    if merged.provider == nil { merged.provider = destination.provider }
                    merged.hasHostname = merged.hasHostname || destination.hasHostname
                }
                destinations[destination.id] = merged
            }
            for tool in summary.tools {
                var merged = tools[tool.id] ?? tool
                if tools[tool.id] != nil {
                    merged.counters += tool.counters
                    merged.destinations += tool.destinations
                }
                tools[tool.id] = merged
            }
        }

        let sortedDestinations = destinations.values.sorted {
            let lhsAI = $0.provider != nil
            let rhsAI = $1.provider != nil
            if lhsAI != rhsAI { return lhsAI }
            if $0.counters.total != $1.counters.total { return $0.counters.total > $1.counters.total }
            return $0.id < $1.id
        }
        return AgentSummary(
            bundleID: known.map(canonicalID) ?? canonical.bundleID,
            name: known?.name ?? canonical.name,
            vendor: known?.vendor ?? ordered.compactMap(\.vendor).sorted().first,
            isKnown: known != nil || ordered.contains(where: \.isKnown),
            appPath: canonical.appPath.nilIfEmpty ?? ordered.map(\.appPath).filter { !$0.isEmpty }.sorted().first ?? "",
            ai: ai,
            egress: egress,
            providers: providers.sorted {
                $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total
            }.map { ($0.key, $0.value) },
            destinations: sortedDestinations,
            tools: tools.values.sorted {
                $0.counters.total == $1.counters.total ? $0.id < $1.id : $0.counters.total > $1.counters.total
            },
            alerts: alerts
        )
    }

    private static func mergedPorts(_ lhs: String, _ rhs: String) -> String {
        let ports = Set((lhs + "," + rhs).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
        return ports.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
            .joined(separator: ", ")
    }

    private static func item(from evidence: Evidence, input: AgentInventoryInput,
                             alertGroups: [AgentOpenAlertCount],
                             openAlertGroupIDsByIdentity: [String: Set<Int>],
                             monitoredIdentityKeys: Set<String>,
                             routeStatesByIdentity: [String: [AgentRouteState]]) -> AgentInventoryItem {
        let known = evidence.known
        let summary = mergedSummary(from: evidence)
        let installed = evidence.installed.sorted { $0.bundleID < $1.bundleID }.first
        let configured = !evidence.workspaces.isEmpty
        let observed = summary.map { !$0.total.isEmpty } ?? false
        let durableAgentIDs = evidence.durableAgentIDs.sorted()
        let rawName = known?.name ?? summary?.name ?? installed?.name ?? durableAgentIDs.first
        let id = known.map(canonicalID) ?? summary?.bundleID ?? installed?.bundleID
            ?? durableAgentIDs.first ?? rawName?.lowercased() ?? "detected-agent"
        let name = rawName.map { safeDisplayName($0, fallback: id) } ?? L("Detected agent")
        let aliases = identityAliases(id: id, name: name, known: known, durableAgentIDs: durableAgentIDs,
                                      installed: evidence.installed, summaries: evidence.summaries)
        let identityPriority = identityPriority(id: id, name: name, known: known,
                                                durableAgentIDs: durableAgentIDs,
                                                installed: evidence.installed, summaries: evidence.summaries)
        let trafficIdentities = trafficIdentityPriority(
            id: id, known: known, durableAgentIDs: durableAgentIDs,
            installed: evidence.installed, summaries: evidence.summaries
        )
        let monitored = !aliases.isDisjoint(with: monitoredIdentityKeys)
        let route = routeState(aliases: aliases, routes: routeStatesByIdentity, monitored: monitored)
        let policy = policyCoverage(identityPriority: identityPriority, summary: summary, policies: input.policies)
        let matchingAlertGroups = aliases.reduce(into: Set<Int>()) { groupIDs, identity in
            groupIDs.formUnion(openAlertGroupIDsByIdentity[identity] ?? [])
        }
        let unresolved = matchingAlertGroups.reduce(0) { $0 + alertGroups[$1].count }
        let health = health(
            observed: observed,
            installed: installed != nil,
            configured: configured,
            monitored: monitored,
            route: route,
            inspection: input.inspection,
            policy: policy,
            unresolvedAlerts: unresolved
        )
        let reasons = reasons(
            observed: observed,
            installed: installed != nil,
            configured: configured,
            monitored: monitored,
            route: route,
            inspection: input.inspection,
            policy: policy,
            unresolvedAlerts: unresolved
        )
        return AgentInventoryItem(
            id: id,
            identities: identityPriority,
            trafficIdentities: trafficIdentities,
            name: name,
            vendor: known?.vendor ?? summary?.vendor,
            appPath: summary?.appPath.nilIfEmpty ?? installed?.path ?? "",
            health: health,
            reasons: reasons,
            installed: installed != nil,
            configured: configured,
            observed: observed,
            autoDiscovered: known == nil && summary != nil,
            alwaysMonitored: monitored,
            route: route,
            policy: policy,
            unresolvedAlerts: unresolved,
            summary: summary
        )
    }

    private static func catalogKey(_ agent: KnownAgent) -> String {
        "known:\(agent.name.lowercased())"
    }

    private static func catalogAgent(matching value: String, preferDisplayName: Bool) -> KnownAgent? {
        let exactName = AgentCatalog.agents.first { $0.name == value }
        let exactIdentifier = AgentCatalog.agents.first { agent in
            agent.bundleIDs.contains(value) || agent.processNames.contains(value)
        }
        let unambiguous = AgentCatalog.knownAgent(identity: value)
        return preferDisplayName
            ? exactName ?? exactIdentifier ?? unambiguous
            : exactIdentifier ?? exactName ?? unambiguous
    }

    private static func safeDisplayName(_ candidate: String, fallback: String) -> String {
        func safe(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80,
                  !trimmed.contains("/"), !trimmed.contains("\\"), !trimmed.contains("://"),
                  trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return trimmed
        }
        return safe(candidate) ?? safe(fallback) ?? L("Detected agent")
    }

    private static func identityAliases(id: String, name: String, known: KnownAgent?,
                                        durableAgentIDs: [String], installed: [InstalledApps.App],
                                        summaries: [AgentSummary]) -> Set<String> {
        let values = [id, name]
            + durableAgentIDs
            + (known?.bundleIDs.sorted() ?? [])
            + (known?.processNames.sorted() ?? [])
            + installed.flatMap { [$0.bundleID, $0.name] }
            + summaries.flatMap { [$0.bundleID, $0.name] }
        return Set(values.map(AgentCatalog.identityComparisonKey))
    }

    private static func identityPriority(id: String, name: String, known: KnownAgent?,
                                         durableAgentIDs: [String], installed: [InstalledApps.App],
                                         summaries: [AgentSummary]) -> [String] {
        let candidates = [id]
            + durableAgentIDs
            + (known?.bundleIDs.sorted() ?? [])
            + (known?.processNames.sorted() ?? [])
            + summaries.map(\.bundleID).sorted()
            + [known?.name, name].compactMap { $0 }
            + installed.map(\.bundleID).sorted()
            + installed.map(\.name).sorted()
            + summaries.map(\.name).sorted()
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func trafficIdentityPriority(
        id: String,
        known: KnownAgent?,
        durableAgentIDs: [String],
        installed: [InstalledApps.App],
        summaries: [AgentSummary]
    ) -> [String] {
        let candidates = [id]
            + (known?.bundleIDs.sorted() ?? [])
            + (known?.processNames.sorted() ?? [])
            + (known == nil ? durableAgentIDs : [])
            + installed.map(\.bundleID).sorted()
            + summaries.map(\.bundleID).sorted()
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func routeState(aliases: Set<String>, routes: [String: [AgentRouteState]],
                                   monitored: Bool) -> AgentRouteState {
        let matches = aliases.flatMap { routes[$0] ?? [] }
        if matches.contains(.failed) { return .failed }
        if matches.contains(.stale) { return .stale }
        if matches.contains(.observed) { return .observed }
        if matches.contains(.configured) || monitored { return .configured }
        return .notRequested
    }

    private static func policyCoverage(identityPriority: [String], summary: AgentSummary?,
                                       policies: [String: AgentPolicy]) -> AgentInventoryPolicyCoverage {
        guard let policy = AgentPolicy.resolve(policies.values, identities: identityPriority),
              policy.enabled else {
            return AgentInventoryPolicyCoverage(enabled: false, enforcing: false, uncoveredDestinations: 0)
        }
        let uncovered = summary?.destinations.filter {
            !policy.allows(host: $0.hasHostname ? $0.label : "", ip: $0.ip, isAIProvider: $0.provider != nil)
        }.count ?? 0
        return AgentInventoryPolicyCoverage(enabled: true, enforcing: policy.enforce,
                                            uncoveredDestinations: uncovered)
    }

    private static func health(observed: Bool, installed: Bool, configured: Bool, monitored: Bool,
                               route: AgentRouteState, inspection: AgentInspectionDiagnostics,
                               policy: AgentInventoryPolicyCoverage, unresolvedAlerts: Int) -> AgentHealthState {
        if unresolvedAlerts > 0 || policy.uncoveredDestinations > 0 || route == .failed || route == .stale {
            return .attention
        }
        guard observed else {
            return configured || monitored || route != .notRequested ? .notObserved : installed ? .inactive : .notObserved
        }
        if inspection.available && (inspection.setupFailed
            || inspection.enabled && (!inspection.running || !inspection.certificateTrusted)) {
            return .needsSetup
        }
        guard inspection.available, inspection.enabled, inspection.running, inspection.certificateTrusted,
              route == .observed else { return .limitedVisibility }
        return .healthy
    }

    /// Reasons are appended in a fixed evidence → route → inspection → policy → alerts order. None interpolate raw
    /// app paths, workspace roots, endpoints, diagnoses, or alert details.
    private static func reasons(observed: Bool, installed: Bool, configured: Bool, monitored: Bool,
                                route: AgentRouteState, inspection: AgentInspectionDiagnostics,
                                policy: AgentInventoryPolicyCoverage, unresolvedAlerts: Int) -> [String] {
        var reasons: [String] = []
        if observed {
            reasons.append(L("Traffic was observed in the selected window."))
        } else if configured {
            reasons.append(L("Configuration was found, but no traffic was observed in the selected window."))
        } else if installed {
            reasons.append(L("Installed on this Mac, with no traffic in the selected window."))
        } else {
            reasons.append(L("No traffic was observed in the selected window."))
        }

        switch route {
        case .notRequested: break
        case .configured:
            reasons.append(L("Always Monitor is configured, but no current route was observed."))
        case .observed:
            reasons.append(L("Its route through Flowlight was observed."))
        case .stale:
            reasons.append(L("The saved Flowlight route was not observed in this window."))
        case .failed:
            reasons.append(L("Flowlight could not establish the requested route."))
        }

        if observed {
            if !inspection.available {
                reasons.append(L("HTTPS inspection is unavailable in this build; only connection metadata is visible."))
            } else if !inspection.enabled {
                reasons.append(L("HTTPS inspection is off; request contents are not visible."))
            } else if !inspection.certificateTrusted {
                reasons.append(L("The HTTPS inspection certificate is not trusted."))
            } else if inspection.setupFailed || !inspection.running {
                reasons.append(L("HTTPS inspection is enabled, but its proxy is not ready."))
            } else if route != .observed {
                reasons.append(L("No inspected requests were observed in this window."))
            } else {
                reasons.append(L("HTTPS inspection observed this agent's traffic."))
            }
        }

        if policy.enabled {
            if policy.uncoveredDestinations > 0 {
                reasons.append(policy.uncoveredDestinations == 1
                    ? L("One observed destination is outside its policy.")
                    : L("%lld observed destinations are outside its policy.", policy.uncoveredDestinations))
            } else {
                reasons.append(policy.enforcing
                    ? L("Its enforcing destination policy covers the observed traffic.")
                    : L("Its reporting destination policy covers the observed traffic."))
            }
        } else if observed || configured || monitored {
            reasons.append(L("No agent destination policy is enabled."))
        }

        if unresolvedAlerts > 0 {
            reasons.append(unresolvedAlerts == 1 ? L("One unresolved alert needs review.")
                : L("%lld unresolved alerts need review.", unresolvedAlerts))
        }
        return reasons
    }
}
