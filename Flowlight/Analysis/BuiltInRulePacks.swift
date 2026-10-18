import Foundation

/// Official lists shipped inside the signed app. They are deliberately small and reviewed in 0.15.0; later remote
/// subscriptions use the same manifest/snapshot boundary but do not change what these built-ins mean.
enum BuiltInRulePacks {
    static let all: [RulePackDefinition] = [advertising, tracking, telemetry]

    static let advertising = definition(
        id: "official.advertising",
        title: "Advertising",
        summary: "Known advertising delivery and auction hosts across apps.",
        caveat: "Connection blocking cannot remove page layout gaps, first-party ads, or overlays drawn by a browser or app.",
        category: .advertising,
        hosts: [
            "adnxs.com", "adsrvr.org", "adservice.google.com", "casalemedia.com", "criteo.com", "criteo.net",
            "doubleclick.net", "googleadservices.com", "googlesyndication.com", "openx.net", "pubmatic.com",
            "rubiconproject.com",
        ])

    static let tracking = definition(
        id: "official.tracking",
        title: "Cross-site tracking",
        summary: "Common analytics, session replay, and cross-site measurement hosts.",
        caveat: "Some apps use the same providers for feature flags. They may fall back to built-in defaults when a host is unavailable.",
        category: .tracking,
        hosts: RuleTemplate.analyticsHosts)

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
        let manifest = RulePackManifest(
            id: id, version: "1", generatedAt: Date(timeIntervalSince1970: 1_792_220_400),
            entryCount: entries.count, contentSHA256: RulePackValidator.digest(entries),
            titleKey: title, summaryKey: summary, caveatKey: caveat,
            source: "Flowlight curated built-in list", license: "GPL-3.0")
        return RulePackDefinition(manifest: manifest, entries: entries)
    }
}
