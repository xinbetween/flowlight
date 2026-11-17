import Foundation

/// Official lists shipped inside the signed app. They are deliberately small and reviewed in 0.15.0; later remote
/// subscriptions use the same manifest/snapshot boundary but do not change what these built-ins mean.
enum BuiltInRulePacks {
    static let all: [RulePackDefinition] = [advertising, advertisingAggressive, tracking, telemetry]

    static let advertising = definition(
        id: AdvertisingPackTierPolicy.balancedID,
        version: "2",
        generatedAt: 1_794_787_199,
        title: "Advertising",
        summary: "Known advertising delivery and auction hosts across apps.",
        caveat: "Recommended balance. Hostname blocking cannot remove page layout gaps, same-origin ads, or overlays drawn by a browser or app.",
        source: "https://flowlight.xinbetween.com/packs/v1/provenance/2c80182d6ca7699d44e9305328b7eff10248031140ca3d9c1c0a95dadc1579e4.json",
        license: "GPL-3.0-or-later",
        entries: [
            entry(1, "adnxs.com", match: .suffix, category: .advertising),
            entry(2, "adservice.google.com", match: .suffix, category: .advertising),
            entry(3, "adsrvr.org", match: .suffix, category: .advertising),
            entry(4, "casalemedia.com", match: .suffix, category: .advertising),
            entry(5, "criteo.com", match: .suffix, category: .advertising),
            entry(6, "criteo.net", match: .suffix, category: .advertising),
            entry(7, "doubleclick.net", match: .suffix, category: .advertising),
            entry(8, "googleadservices.com", match: .suffix, category: .advertising),
            entry(9, "googlesyndication.com", match: .suffix, category: .advertising),
            entry(13, "imp9.pubadx.one", category: .advertising),
            entry(10, "openx.net", match: .suffix, category: .advertising),
            entry(14, "platform.pubadx.one", category: .advertising),
            entry(11, "pubmatic.com", match: .suffix, category: .advertising),
            entry(12, "rubiconproject.com", match: .suffix, category: .advertising),
        ])

    static let advertisingAggressive = definition(
        id: AdvertisingPackTierPolicy.aggressiveID,
        version: "1",
        generatedAt: 1_794_787_199,
        title: "Advertising — Aggressive",
        summary: "Broader advertising hostname coverage for users who accept a higher risk of broken content.",
        caveat: "Opt-in and higher breakage risk. This tier replaces Advertising; it does not stack with it.",
        source: "https://flowlight.xinbetween.com/packs/v1/provenance/2c80182d6ca7699d44e9305328b7eff10248031140ca3d9c1c0a95dadc1579e4.json",
        license: "GPL-3.0-or-later",
        entries: [
            entry(1, "adnxs.com", match: .suffix, category: .advertising),
            entry(2, "adservice.google.com", match: .suffix, category: .advertising),
            entry(3, "adsrvr.org", match: .suffix, category: .advertising),
            entry(4, "casalemedia.com", match: .suffix, category: .advertising),
            entry(5, "criteo.com", match: .suffix, category: .advertising),
            entry(6, "criteo.net", match: .suffix, category: .advertising),
            entry(7, "doubleclick.net", match: .suffix, category: .advertising),
            entry(8, "googleadservices.com", match: .suffix, category: .advertising),
            entry(9, "googlesyndication.com", match: .suffix, category: .advertising),
            entry(10, "openx.net", match: .suffix, category: .advertising),
            entry(15, "pubadx.one", match: .suffix, category: .advertising),
            entry(11, "pubmatic.com", match: .suffix, category: .advertising),
            entry(12, "rubiconproject.com", match: .suffix, category: .advertising),
        ])

    static let tracking = definition(
        id: "official.tracking",
        version: "2",
        generatedAt: 1_793_253_368,
        title: "Cross-site tracking",
        summary: "Dedicated analytics collection, session replay, and tracker bootstrap hosts.",
        caveat: "Product dashboards stay reachable. Shared-host collection paths and first-party tracking proxies cannot be separated by hostname blocking.",
        entries: [
            entry(1, "api-eu.mixpanel.com"),
            entry(2, "api-in.mixpanel.com"),
            entry(3, "api-js.mixpanel.com"),
            entry(4, "api.eu.amplitude.com"),
            entry(5, "api.mixpanel.com"),
            entry(6, "api.segment.io"),
            entry(7, "api2.amplitude.com"),
            entry(8, "browser-intake-ap1-datadoghq.com"),
            entry(9, "browser-intake-ap2-datadoghq.com"),
            entry(10, "browser-intake-datadoghq.com", match: .suffix),
            entry(11, "browser-intake-datadoghq.eu"),
            entry(12, "browser-intake-ddog-gov.com"),
            entry(13, "browser-intake-uk1-datadoghq.com"),
            entry(14, "browser-intake-us2-ddog-gov.com"),
            entry(15, "browser-intake-us3-datadoghq.com"),
            entry(16, "browser-intake-us5-datadoghq.com"),
            entry(17, "c.eu.heap-api.com"),
            entry(18, "c.us.heap-api.com"),
            entry(19, "cdn.eu.heap-api.com"),
            entry(20, "cdn.heapanalytics.com"),
            entry(21, "cdn.matomo.cloud"),
            entry(22, "cdn.mxpnl.com"),
            entry(23, "cdn.us.heap-api.com"),
            entry(24, "clarity.ms", match: .suffix),
            entry(25, "edge.eu1.fullstory.com"),
            entry(26, "edge.fullstory.com"),
            entry(27, "eu-assets.i.posthog.com"),
            entry(28, "eu.i.posthog.com"),
            entry(29, "events.eu1.segmentapis.com"),
            entry(30, "events.statsigapi.net"),
            entry(31, "google-analytics.com", match: .suffix),
            entry(32, "googletagmanager.com", match: .suffix),
            entry(33, "lr-ingest.com", match: .suffix),
            entry(34, "lr-ingest.io", match: .suffix),
            entry(35, "lr-intake.com", match: .suffix),
            entry(36, "lrkt-in.com", match: .suffix),
            entry(37, "prodregistryv2.org", match: .suffix),
            entry(38, "r.logrocket.com"),
            entry(39, "rs.eu1.fullstory.com"),
            entry(40, "rs.fullstory.com"),
            entry(41, "services.fullstory.com"),
            entry(42, "us-assets.i.posthog.com"),
            entry(43, "us.i.posthog.com"),
        ])

    static let telemetry = definition(
        id: "official.telemetry",
        title: "Privacy and telemetry",
        summary: "Crash reporting, install attribution, and audited Apple advertising and analytics hosts.",
        caveat: "Crash reports help developers fix failures. Essential Apple account, push, update, certificate, and iCloud traffic stays allowed.",
        category: .telemetry,
        hosts: RuleTemplate.crashReportingHosts + RuleTemplate.attributionHosts + RuleTemplate.appleTelemetryHosts)

    private static func definition(id: String, title: String, summary: String, caveat: String,
                                   category: RulePackEntry.Category, hosts: [String]) -> RulePackDefinition {
        let canonical = Array(Set(hosts.compactMap(HostCanonicalizer.host))).sorted()
        let entries = canonical.enumerated().map {
            RulePackEntry(id: UInt32($0.offset + 1), host: $0.element, match: .suffix, category: category)
        }
        return definition(id: id, version: "1", generatedAt: 1_792_220_400,
                          title: title, summary: summary, caveat: caveat, entries: entries)
    }

    private static func definition(id: String, version: String, generatedAt: TimeInterval,
                                   title: String, summary: String, caveat: String,
                                   source: String = "Flowlight curated built-in list",
                                   license: String = "GPL-3.0",
                                   entries: [RulePackEntry]) -> RulePackDefinition {
        let manifest = RulePackManifest(
            id: id, version: version, generatedAt: Date(timeIntervalSince1970: generatedAt),
            entryCount: entries.count, contentSHA256: RulePackValidator.digest(entries),
            titleKey: title, summaryKey: summary, caveatKey: caveat,
            source: source, license: license)
        return RulePackDefinition(manifest: manifest, entries: entries)
    }

    private static func entry(_ id: UInt32, _ host: String,
                              match: RulePackEntry.Match = .exact,
                              category: RulePackEntry.Category = .tracking) -> RulePackEntry {
        RulePackEntry(id: id, host: host, match: match, category: category)
    }
}
