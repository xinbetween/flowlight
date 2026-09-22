import AppKit
import Foundation

/// HTTPS inspection: an opt-in mode, off by default, that decrypts the traffic of apps routed through Flowlight's
/// local proxy using a certificate authority created on this Mac. Everything it records stays in the local database.
@MainActor
final class InspectionController: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case agents, all
        var id: String { rawValue }
        var title: String { self == .agents ? "AI agents and their tools" : "Every app that uses the proxy" }
    }

    enum Keys {
        static let enabled = "inspection.enabled"
        static let port = "inspection.port"
        static let scope = "inspection.scope"
        static let neverInspect = "inspection.neverInspect"
        static let retentionDays = "inspection.retentionDays"
        static let systemProxy = "inspection.systemProxy"
    }

    /// Hosts that are never decrypted, even when routed through the proxy: Apple services (many pin certificates and
    /// carry account data) and password managers.
    nonisolated static let defaultNeverInspect = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "mzstatic.com", "cdn-apple.com",
        "1password.com", "1password.ca", "1password.eu", "bitwarden.com", "lastpass.com", "dashlane.com", "keepersecurity.com",
    ]

    @Published private(set) var running = false
    @Published private(set) var port: UInt16?
    @Published private(set) var trusted = false
    @Published private(set) var caExists = false
    @Published var lastError: String?
    @Published private(set) var recordedCount = 0
    @Published private(set) var systemProxyOn = false

    private let proxy = InspectionProxy()
    private let recorder = InspectionRecorder()
    private let ca = CertificateAuthority.shared
    private weak var db: TrafficDatabase?
    private var pruneTimer: Timer?
    var onRecorded: () -> Void = {}

    init() {
        UserDefaults.standard.register(defaults: [
            Keys.enabled: false, Keys.port: 8877, Keys.scope: Scope.agents.rawValue,
            Keys.neverInspect: Self.defaultNeverInspect, Keys.retentionDays: 3, Keys.systemProxy: false,
        ])
        proxy.observer = recorder
        recorder.proxyPort = { [proxy] in proxy.port }
        proxy.onStateChange = { [weak self, proxy] message in
            Task { @MainActor in
                self?.running = proxy.port != nil
                self?.port = proxy.port
                if let message { self?.lastError = message }
            }
        }
        proxy.pacScript = { [proxy] in
            Self.pacScript(port: proxy.port ?? 8877,
                           never: UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect)
        }
        let scopeAndList = { () -> (Scope, [String]) in
            (Scope(rawValue: UserDefaults.standard.string(forKey: Keys.scope) ?? "") ?? .agents,
             UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect)
        }
        let decide = DispatchQueue(label: "flowlight.inspect.decide", qos: .userInitiated, attributes: .concurrent)
        proxy.shouldInspect = { [recorder, proxy] host, clientPort, answer in
            let (scope, never) = scopeAndList()
            guard !Self.matches(host: host, patterns: never) else { answer(false); return }
            guard scope == .agents else { answer(true); return }
            decide.async {
                answer(recorder.owner(clientPort: clientPort, proxyPort: proxy.port).agent != nil)
            }
        }
        recorder.onExchange = { [weak self] exchange in
            // Plain-HTTP requests reach the recorder regardless of scope; keep only what the scope allows.
            let (scope, _) = scopeAndList()
            guard scope == .all || exchange.agent != nil || exchange.note != nil else { return }
            guard let self else { return }
            Task { @MainActor in
                self.db?.async { try $0.insertExchange(exchange) }
                self.recordedCount += 1
                self.onRecorded()
            }
        }
        refreshStatus()
    }

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled); objectWillChange.send(); apply() }
    }

    var scope: Scope {
        get { Scope(rawValue: UserDefaults.standard.string(forKey: Keys.scope) ?? "") ?? .agents }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.scope); objectWillChange.send() }
    }

    var neverInspect: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.neverInspect) ?? Self.defaultNeverInspect }
        set { UserDefaults.standard.set(newValue, forKey: Keys.neverInspect); objectWillChange.send() }
    }

    var configuredPort: UInt16 { UInt16(clamping: max(1024, UserDefaults.standard.integer(forKey: Keys.port))) }

    func attach(db: TrafficDatabase) {
        self.db = db
        guard !DemoData.isEnabled else { return }
        apply()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        prune()
    }

    /// Starts or stops the proxy to match the setting.
    func apply() {
        refreshStatus()
        if enabled && !DemoData.isEnabled {
            do { try ca.ensure() } catch { lastError = error.localizedDescription; return }
            caExists = true
            proxy.start(port: configuredPort)
        } else {
            if systemProxyOn { setSystemProxy(false) }
            proxy.stop()
        }
    }

    func refreshStatus() {
        caExists = ca.exists
        trusted = caExists && ca.isTrusted
        systemProxyOn = UserDefaults.standard.bool(forKey: Keys.systemProxy)
    }

    private func prune() {
        let days = max(1, UserDefaults.standard.integer(forKey: Keys.retentionDays))
        db?.async { try $0.pruneExchanges(olderThan: Date().addingTimeInterval(-Double(days) * 86400)) }
    }

    // MARK: Certificate

    func trustCertificate() {
        lastError = nil
        Task.detached { [ca] in
            do { try ca.trust() } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run { self.refreshStatus() }
        }
    }

    /// Turns inspection off, removes the system proxy, deletes the CA, its trust setting and every recorded exchange.
    func removeEverything() {
        enabled = false
        let db = db
        Task.detached { [ca] in
            ca.remove()
            db?.async { try $0.deleteAllExchanges() }
            await MainActor.run { self.recordedCount = 0; self.refreshStatus(); self.onRecorded() }
        }
    }

    func revealCertificate() {
        NSWorkspace.shared.activateFileViewerSelecting([ca.caCertificateURL])
    }

    // MARK: Routing

    /// Environment variables that route command-line agents (Claude Code, Codex, Gemini CLI, Aider…) and their tools
    /// through the proxy and make them trust the Flowlight CA. Nothing else on the Mac is affected.
    var shellSetup: String {
        let proxyURL = "http://127.0.0.1:\(port ?? configuredPort)"
        let bundle = ca.bundleURL.path, caPath = ca.caCertificateURL.path
        return """
        # Flowlight HTTPS inspection: route this shell's tools through Flowlight
        export HTTPS_PROXY=\(proxyURL) HTTP_PROXY=\(proxyURL) https_proxy=\(proxyURL) http_proxy=\(proxyURL)
        export NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1
        export NODE_USE_ENV_PROXY=1 NODE_EXTRA_CA_CERTS="\(caPath)"
        export SSL_CERT_FILE="\(bundle)" REQUESTS_CA_BUNDLE="\(bundle)" CURL_CA_BUNDLE="\(bundle)" GIT_SSL_CAINFO="\(bundle)"
        """
    }

    func copyShellSetup() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellSetup, forType: .string)
    }

    /// Opens a Terminal window with the setup applied; agents started there are inspected.
    func openInspectedTerminal() {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("Flowlight Inspected Shell.command")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let body = """
        #!/bin/sh
        \(shellSetup)
        clear
        echo "Flowlight is inspecting HTTPS from this window. Agents you start here show up in Flowlight › Inspect."
        exec \(shell) -l
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            lastError = "Couldn't open a Terminal window: \(error.localizedDescription)"
        }
    }

    /// The proxy auto-config served to apps that follow system proxy settings. It falls back to a direct connection
    /// when Flowlight isn't running, so quitting Flowlight never cuts the Mac off.
    nonisolated static func pacScript(port: UInt16, never patterns: [String]) -> String {
        let proxy = "PROXY 127.0.0.1:\(port); DIRECT"
        let never = patterns.map { "\"\(Self.jsString($0))\"" }.joined(separator: ", ")
        return """
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (isPlainHostName(host) || host == "localhost" || shExpMatch(host, "127.*") || shExpMatch(host, "10.*") ||
              shExpMatch(host, "192.168.*") || shExpMatch(host, "*.local")) return "DIRECT";
          var never = [\(never)];
          for (var i = 0; i < never.length; i++) {
            if (host == never[i] || dnsDomainIs(host, "." + never[i])) return "DIRECT";
          }
          return "\(proxy)";
        }
        """
    }

    /// Points every enabled network service's automatic proxy configuration at Flowlight's PAC file, or restores it.
    /// macOS asks for an administrator password.
    func setSystemProxy(_ on: Bool) {
        let services = SystemProxy.services()
        guard !services.isEmpty else { lastError = "No network services found."; return }
        let pac = "http://127.0.0.1:\(port ?? configuredPort)/proxy.pac"
        let commands = services.flatMap { service -> [String] in
            let quoted = InspectionShell.quote(service)
            return on
                ? ["/usr/sbin/networksetup -setautoproxyurl \(quoted) \(pac)", "/usr/sbin/networksetup -setautoproxystate \(quoted) on"]
                : ["/usr/sbin/networksetup -setautoproxystate \(quoted) off"]
        }
        let source = "do shell script \(InspectionShell.appleScriptQuote(commands.joined(separator: " && "))) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) != -128 {
                lastError = "Couldn't change the proxy settings: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
            }
            return
        }
        UserDefaults.standard.set(on, forKey: Keys.systemProxy)
        refreshStatus()
    }

    // MARK: Matching

    nonisolated static func matches(host: String, patterns: [String]) -> Bool {
        let host = host.lowercased()
        return patterns.contains { raw in
            let p = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " *."))
            return !p.isEmpty && (host == p || host.hasSuffix("." + p))
        }
    }

    nonisolated private static func jsString(_ s: String) -> String {
        s.filter { $0.isLetter || $0.isNumber || "-._".contains($0) }
    }
}

enum SystemProxy {
    /// Enabled network service names ("Wi-Fi", "Ethernet"). Disabled services are listed with a leading asterisk.
    static func services() -> [String] {
        let result = CertificateAuthority.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard result.status == 0 else { return [] }
        return result.output.split(separator: "\n").dropFirst()
            .map(String.init).filter { !$0.hasPrefix("*") && !$0.isEmpty }
    }
}

enum InspectionShell {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
