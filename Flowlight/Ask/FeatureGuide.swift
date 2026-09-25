import Foundation

/// What every feature of Flowlight does, where it lives, and how to switch it on.
///
/// "How do I turn on HTTPS inspection?" is a fair question to put to a panel that answers questions about the app,
/// and until there was something like this the model had nothing to answer it from — so it would either refuse or,
/// worse, invent a menu path. This is written down here rather than left to the model's memory precisely so the
/// answer is the one true for this build.
///
/// It is also the shape of the promise: the model may read these entries, and that is all. Nothing here changes a
/// setting. When an answer needs one changed, it says where the switch is and the answer offers to open that
/// screen, which is a click the person makes.
struct FeatureGuide: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// What it is, in a sentence or two.
    var summary: String
    /// How to turn it on or use it, as steps someone can follow.
    var steps: [String]
    /// Where it lives, so an answer can offer to go there.
    var screen: SidebarItem?
    /// What it can't do. Left out of an answer, these are the things people discover the hard way.
    var caveats: [String] = []
    /// Extra words someone might use for it.
    var keywords: [String] = []

    var searchText: String {
        ([id, title, summary] + steps + caveats + keywords).joined(separator: " ").lowercased()
    }

    /// The whole of it, as the model receives it.
    var asDictionary: [String: String] {
        var out = ["feature": title, "what": summary, "how": steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")]
        if let screen { out["where"] = screen.englishTitle }
        if !caveats.isEmpty { out["limits"] = caveats.joined(separator: " ") }
        return out
    }
}

extension FeatureGuide {
    /// Everything Flowlight can do. A feature missing from here is a feature the Ask panel cannot explain, so it
    /// is worth adding to when one is added to the app.
    static let all: [FeatureGuide] = [
        FeatureGuide(
            id: "capture", title: "Capture source",
            summary: "Where traffic comes from. The Network Extension is a content filter that sits in the data path and attributes every flow to its app; the nettop sampler needs no entitlement but samples once a second and misses flows shorter than that.",
            steps: ["Open Capture.", "Under Capture source, pick Network Extension or nettop sampler.",
                    "For the extension, press Install & enable filter and approve it in System Settings."],
            screen: .capture,
            caveats: ["macOS runs one content filter at a time. If a VPN or a security agent holds that slot, Flowlight's filter installs and connects but is never handed a flow.",
                      "Only the extension can refuse a connection. The sampler counts traffic after the fact."],
            keywords: ["nettop", "network extension", "content filter", "source", "no traffic", "nothing showing"]),

        FeatureGuide(
            id: "hostnames", title: "Hostnames",
            summary: "Turning IP addresses into names. The extension reads TLS SNI and DNS answers itself. On the sampler, a one-time packet-capture setup is what lets Flowlight see those names.",
            steps: ["Open Capture.", "Turn on Read hostnames from the network.", "Give the helper permission when macOS asks."],
            screen: .capture,
            caveats: ["Without it the sampler falls back to reverse DNS, which is often missing or wrong."],
            keywords: ["dns", "sni", "domain", "ip only", "no domain names", "bpf", "packet capture"]),

        FeatureGuide(
            id: "focus", title: "Focus mode",
            summary: "Narrows every screen to the apps and destinations you pick. One app is a focus; so is one destination. It filters what you see, never what is recorded.",
            steps: ["Click Focus at the bottom of the sidebar, or press ⇧⌘F.",
                    "Add an app by name or bundle identifier, or a destination by domain or address.",
                    "Turn Focus off to see everything again."],
            screen: nil,
            caveats: ["Alerts record the app that raised them and nothing about where the traffic went, so a focus made only of destinations leaves the alert list alone."],
            keywords: ["filter", "narrow", "only show", "one app"]),

        FeatureGuide(
            id: "background", title: "Running in the background",
            summary: "Flowlight can keep recording with no window open, as a menu bar item showing live rates.",
            steps: ["Open Settings with ⌘, and go to General.", "Turn on Keep running in the background.",
                    "Optionally turn on Show rates in the menu bar."],
            screen: nil,
            keywords: ["menu bar", "background", "close window", "quit", "dock icon", "hide"]),

        FeatureGuide(
            id: "agents", title: "AI agents",
            summary: "Flowlight recognises AI agents by name and spots any other process that calls an LLM API. Traffic from tools and MCP servers an agent started counts as that agent's.",
            steps: ["Open AI Agents.", "Pick an agent to see its model providers, everything else it reached, its tools and its MCP servers."],
            screen: .agents,
            keywords: ["claude", "codex", "cursor", "copilot", "agent", "mcp", "llm"]),

        FeatureGuide(
            id: "allowlists", title: "Agent allowlists",
            summary: "\"Claude Code may talk to GitHub and npm, nothing else.\" Anything else raises an alert, and with enforcement on the extension refuses the connection too.",
            steps: ["Open AI Agents and select the agent.", "Under Allowlist, add domains, addresses or ranges, or start from a preset.",
                    "To refuse rather than warn, turn on Refuse connections outside the list."],
            screen: .agents,
            caveats: ["Refusing needs the Network Extension. Local traffic, DNS, Apple services and Flowlight's own connections are never refused."],
            keywords: ["allowlist", "allow", "whitelist", "block agent", "enforce"]),

        FeatureGuide(
            id: "rules", title: "Rules",
            summary: "Block or allow anything: an app, an agent, a destination, a URL, or a pairing of those — forever, until a time, until Flowlight quits, or between chosen hours. The most specific rule wins and a tie goes to the block.",
            steps: ["Open Rules and press ＋, or right-click any row in Live, Reports, AI Agents or Inspect and choose Block.",
                    "Name an app or a destination, pick block or allow, and choose how long it lasts.",
                    "Pause Blocking in the toolbar stands every rule down for a while."],
            screen: .rules,
            caveats: ["A rule that names a path can only be carried out by HTTPS inspection; one that names a host needs the Network Extension. A rule the current setup can't enforce says so in the list."],
            keywords: ["block", "refuse", "deny", "firewall", "stop app", "allow once", "pause"]),

        FeatureGuide(
            id: "guardrails", title: "Agent guardrails",
            summary: "Block an MCP server, one of its tools, or a resource. A refused tool is removed from the list the agent sends its model, so the model is never offered it.",
            steps: ["Open AI Agents and select the agent.", "Choose the Guardrails tab.",
                    "Switch off a tool or a server, or apply a preset such as read-only, no shell or no writes."],
            screen: .agents,
            caveats: ["Needs HTTPS inspection, because the tool list lives inside a request body.",
                      "It is not a sandbox: an agent that still has a shell can do by hand what the tool would have done."],
            keywords: ["tool", "mcp", "guardrail", "read-only", "no shell", "block tool"]),

        FeatureGuide(
            id: "inspection", title: "HTTPS inspection",
            summary: "Optional. Decrypts the traffic of apps routed through Flowlight's local proxy using a certificate authority created on this Mac, so you can see requests, responses and the tool calls behind them.",
            steps: ["Open Inspect.", "Press Turn on HTTPS inspection and approve the certificate when asked.",
                    "Choose whether to route AI agents only or every app that uses the proxy."],
            screen: .inspect,
            caveats: ["Apple services and password managers are never decrypted. Apps that pin certificates are passed through untouched.",
                      "Everything it records stays in the local database and is pruned after a few days."],
            keywords: ["decrypt", "tls", "proxy", "certificate", "mitm", "requests", "bodies"]),

        FeatureGuide(
            id: "mocks", title: "Mock responses",
            summary: "Answer a chosen endpoint yourself instead of letting the request reach the server — a 500, a rate limit, a malformed body or a long wait — and watch what the agent does about it.",
            steps: ["Turn on HTTPS inspection.", "Open Inspect and right-click a recorded request, or open the mock rules in the inspection settings.",
                    "Give the rule a host, a path, a status and a body."],
            screen: .inspect,
            caveats: ["Only requests Flowlight decrypts can be mocked."],
            keywords: ["mock", "stub", "fake", "503", "simulate failure", "test agent"]),

        FeatureGuide(
            id: "alerts", title: "Alerts",
            summary: "Explainable, per-app alerts: traffic spikes, unusual numbers of destinations, first contact with a domain, sensitive channels, possible exfiltration, agents active while you are away, and refused connections.",
            steps: ["Open Alerts to review them.", "Adjust the thresholds in Settings ⌘, under Detection."],
            screen: .alerts,
            caveats: ["Every app gets a learning period before first-contact and spike rules fire."],
            keywords: ["alert", "anomaly", "warning", "threshold", "notification", "exfiltration"]),

        FeatureGuide(
            id: "reports", title: "Reports",
            summary: "History from second to year, grouped by app, destination or address, with charts, a Worth a look mode that points at apps whose destinations don't resemble their peers, and CSV export.",
            steps: ["Open Reports.", "Pick a granularity, then group by App › Domain › IP, Destination › App › IP, or IP › App.",
                    "Use the Way out menu to narrow to the network, peer-to-peer Wi-Fi, this Mac or a tunnel."],
            screen: .reports,
            keywords: ["history", "chart", "csv", "export csv", "breakdown", "worth a look", "group"]),

        FeatureGuide(
            id: "channels", title: "Peer-to-peer Wi-Fi",
            summary: "AirDrop, Handoff, AirPlay, Sidecar and Universal Control go straight to a device in the room over AWDL. Flowlight labels those flows rather than showing them as traffic to an address with no name.",
            steps: ["Open Reports.", "Use the Way out menu in the toolbar and choose Peer-to-peer Wi-Fi."],
            screen: .reports,
            keywords: ["airdrop", "awdl", "handoff", "airplay", "sidecar", "peer to peer", "nearby"]),

        FeatureGuide(
            id: "devices", title: "Devices: Bluetooth and USB",
            summary: "Which devices are paired or attached, which are connected, and when that changed. Off until you turn it on.",
            steps: ["Open Devices.", "Press Watch Bluetooth or Watch USB and external storage."],
            screen: .devices,
            caveats: ["No byte counts: macOS keeps no per-app accounting for these channels.",
                      "The app list is who asked for Bluetooth access, not who was granted it."],
            keywords: ["bluetooth", "usb", "drive", "paired", "airpods", "external storage"]),

        FeatureGuide(
            id: "export", title: "Export to OpenTelemetry or a SIEM",
            summary: "Sends rollups and alerts to a collector you choose. There is no default endpoint and nothing is sent until you set one.",
            steps: ["Open Settings with ⌘, and go to Export.", "Set the endpoint and choose OTLP or newline-delimited JSON.",
                    "Pick which fields may leave, and add any headers your collector needs."],
            screen: nil,
            caveats: ["Headers are kept in the login Keychain, not in preferences.",
                      "Whatever it sends appears in Live and Reports like any other app's traffic."],
            keywords: ["otlp", "siem", "splunk", "datadog", "collector", "opentelemetry", "forward"]),

        FeatureGuide(
            id: "ask", title: "Ask",
            summary: "Questions in plain language, answered from the history on this Mac. The model is handed a fixed set of read-only queries and never the database.",
            steps: ["Open Ask and type a question.", "Choose who answers from the provider button in the toolbar: the on-device model, a local server, or a provider you have a key for."],
            screen: .ask,
            caveats: ["With a hosted provider, your question and the query results leave the Mac. Every request is shown under the answer."],
            keywords: ["ask", "question", "chat", "llm", "ollama", "on-device", "provider", "api key"]),

        FeatureGuide(
            id: "data", title: "Your data and retention",
            summary: "Everything is a SQLite database in Application Support. Seconds are kept briefly, minutes and hours longer, daily totals indefinitely, alerts for 90 days.",
            steps: ["Open Capture and use Clear all data to delete everything.",
                    "Or remove ~/Library/Application Support/Flowlight."],
            screen: .capture,
            keywords: ["delete", "database", "retention", "privacy", "clear", "storage", "disk"]),

        FeatureGuide(
            id: "updates", title: "Updates",
            summary: "Flowlight checks for new releases and can install them for you. Releases are signed with a Developer ID and notarized by Apple.",
            steps: ["Choose Flowlight › Check for Updates.", "Or install with Homebrew: brew install --cask xinbetween/tap/flowlight."],
            screen: nil,
            keywords: ["update", "upgrade", "version", "homebrew", "brew", "new release"]),
    ]

    /// The entries that match what was asked, best first. A plain keyword score rather than anything clever: the
    /// corpus is twenty short entries, and a model that gets two near-misses alongside the right one can read.
    static func search(_ query: String, in guides: [FeatureGuide] = all, limit: Int = 4) -> [FeatureGuide] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        guard !words.isEmpty else { return Array(guides.prefix(limit)) }
        let scored = guides.map { guide -> (FeatureGuide, Int) in
            let text = guide.searchText
            var score = 0
            for word in words where text.contains(word) {
                score += 1
                // A word in the title or the keywords is worth more than one buried in a caveat.
                if guide.title.lowercased().contains(word) { score += 3 }
                if guide.keywords.contains(where: { $0.contains(word) }) { score += 2 }
            }
            return (guide, score)
        }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        return hits.isEmpty ? [] : hits.prefix(limit).map(\.0)
    }
}
