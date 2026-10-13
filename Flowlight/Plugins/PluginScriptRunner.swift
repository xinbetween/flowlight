import Foundation

/// Runs installed advisory plugin scripts out of process. Scripts receive sanitized metadata only and can return bounded findings.
final class PluginScriptRunner: @unchecked Sendable {
    static let shared = PluginScriptRunner()
    static let maxScriptBytes = 128 * 1024
    static let maxInputBytes = 512 * 1024
    static let maxOutputBytes = 512 * 1024
    static let timeout: TimeInterval = 0.25

    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }

    private init() {}

    func evaluate(exchange: HTTPExchange, manifests: [PluginManifest]) -> [PluginFindingDraft] {
        manifests.flatMap { evaluate(exchange: exchange, manifest: $0) }
    }

    func evaluate(exchange: HTTPExchange, manifest: PluginManifest) -> [PluginFindingDraft] {
        guard manifest.enabled, manifest.source == .installed, !manifest.script.isEmpty,
              manifest.script.lengthOfBytes(using: .utf8) <= Self.maxScriptBytes else { return [] }
        let input: [String: Any] = [
            "mode": "plugin",
            "script": manifest.script,
            "manifest": manifestPayload(manifest),
            "context": contextPayload(exchange, permissions: Set(manifest.permissions)),
        ]
        guard JSONSerialization.isValidJSONObject(input),
              let encoded = try? JSONSerialization.data(withJSONObject: input), encoded.count <= Self.maxInputBytes,
              let executable = helperURL() else { return [] }
        let process = Process()
        process.executableURL = executable
        process.arguments = []
        process.environment = [:]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        let outputDone = DispatchSemaphore(value: 0)
        let output = OutputCapture()
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputDone.signal()
        }
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return [] }
        stdin.fileHandleForWriting.write(encoded)
        try? stdin.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + Self.timeout) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.1)
            }
            _ = outputDone.wait(timeout: .now() + 0.1)
            return []
        }
        guard outputDone.wait(timeout: .now() + 0.1) == .success,
              process.terminationStatus == 0 else { return [] }
        let captured = output.get()
        guard captured.count <= Self.maxOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: captured) as? [String: Any],
              let rawFindings = object["findings"] as? [[String: Any]] else { return [] }
        return rawFindings.prefix(8).compactMap { draft(from: $0, manifest: manifest, exchange: exchange) }
    }

    private func draft(from object: [String: Any], manifest: PluginManifest, exchange: HTTPExchange) -> PluginFindingDraft? {
        guard let severityText = object["severity"] as? String,
              let severity = PluginFinding.Severity(rawValue: severityText),
              let title = object["title"] as? String, !title.isEmpty, title.count <= 120,
              let summary = object["summary"] as? String, !summary.isEmpty, summary.count <= 500 else { return nil }
        let evidenceObjects = (object["evidence"] as? [[String: Any]]) ?? []
        let evidence = evidenceObjects.prefix(8).compactMap { item -> PluginEvidence? in
            guard let label = item["label"] as? String, let value = item["value"] as? String,
                  !label.isEmpty, !value.isEmpty else { return nil }
            return PluginEvidence(label, value)
        }
        let maySuggest = manifest.capabilities.contains(.suggestGuardrail) && manifest.permissions.contains(.suggestGuardrail)
        let guardrail = maySuggest ? suggestedGuardrail(from: object["suggestedGuardrail"], exchange: exchange) : nil
        let rule = maySuggest ? suggestedRule(from: object["suggestedRule"], exchange: exchange) : nil
        return PluginFindingDraft(pluginID: manifest.id, pluginVersion: manifest.version, kind: manifest.kind, severity: severity,
                                  title: title, summary: summary, evidence: evidence,
                                  suggestedGuardrail: guardrail, suggestedRule: rule)
    }

    private func suggestedGuardrail(from value: Any?, exchange: HTTPExchange) -> Guardrail? {
        guard let object = value as? [String: Any] else { return nil }
        var guardrail = Guardrail(agent: limited(object["agent"], fallback: exchange.agent ?? "", count: 120),
                                  server: limited(object["server"], count: 120),
                                  tool: limited(object["tool"], count: 120),
                                  origin: .observed)
        guardrail.resource = limited(object["resource"], count: 240)
        guardrail.name = limited(object["name"], count: 120)
        return guardrail.isComplete ? guardrail : nil
    }

    private func suggestedRule(from value: Any?, exchange: HTTPExchange) -> Rule? {
        guard let object = value as? [String: Any] else { return nil }
        let action = Rule.Action(rawValue: limited(object["action"], fallback: "block", count: 20)) ?? .block
        let destination = limited(object["destination"], fallback: exchange.host, count: 240)
        var rule = Rule(action: action,
                        app: limited(object["app"], fallback: exchange.agent ?? exchange.bundleID, count: 160),
                        destination: AgentPolicy.normalize(destination) ?? destination.lowercased(),
                        path: limited(object["path"], count: 240),
                        method: limited(object["method"], count: 20).uppercased(),
                        origin: .alert)
        if let status = object["status"] as? Int { rule.status = min(max(status, 400), 599) }
        rule.name = limited(object["name"], count: 120)
        return rule.isComplete ? rule : nil
    }

    private func limited(_ value: Any?, fallback: String = "", count: Int = 120) -> String {
        String(((value as? String) ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines).prefix(count))
    }

    private func manifestPayload(_ manifest: PluginManifest) -> [String: Any] {
        [
            "id": manifest.id,
            "name": manifest.name,
            "version": manifest.version,
            "kind": manifest.kind.rawValue,
            "publisher": manifest.publisher.rawValue,
            "guardrailProvider": manifest.guardrailProvider.rawValue,
            "capabilities": manifest.capabilities.map(\.rawValue),
            "permissions": manifest.permissions.map(\.rawValue),
            "privacy": [
                "categories": manifest.privacy.categories.map(\.rawValue),
                "summary": manifest.privacy.summary,
            ],
            "configuration": manifest.configuration,
        ]
    }

    private func contextPayload(_ exchange: HTTPExchange, permissions: Set<PluginPermission>) -> [String: Any] {
        func value<T>(_ optional: T?) -> Any { optional ?? NSNull() }
        var context: [String: Any] = [:]
        if permissions.contains(.trafficMetadata) {
            context.merge([
                "method": exchange.method,
                "scheme": exchange.scheme,
                "host": exchange.host,
                "port": exchange.port,
                "path": exchange.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? exchange.path,
                "status": value(exchange.status),
                "requestSize": exchange.requestSize,
                "responseSize": exchange.responseSize,
                "requestTruncated": exchange.requestTruncated,
                "responseTruncated": exchange.responseTruncated,
                "contentType": exchange.contentType,
            ]) { current, _ in current }
        }
        if permissions.contains(.headerNames) {
            context["requestHeaderNames"] = exchange.requestHeaders.map { $0.name }
            context["responseHeaderNames"] = exchange.responseHeaders.map { $0.name }
        }
        if permissions.contains(.appIdentity) {
            context["bundleID"] = exchange.bundleID
            context["appName"] = exchange.appName
            context["agent"] = value(exchange.agent)
            context["agentName"] = value(exchange.agentName)
            context["mcpServer"] = value(exchange.mcpServer)
        }
        if permissions.contains(.mcpMetadata) {
            context["toolCalls"] = exchange.toolCalls.map { tool in
                ["source": tool.source.rawValue, "name": tool.name, "mcpServer": value(tool.mcpServer)]
            }
            context["mcp"] = exchange.mcp.map { activity in
                ["server": activity.server, "endpoint": activity.endpoint, "method": activity.method,
                 "tool": value(activity.tool), "tools": value(activity.tools), "version": value(activity.version),
                 "isError": activity.isError]
            }
        }
        if permissions.contains(.llmMetadata), let llm = exchange.llm {
            context["llm"] = [
                "provider": llm.provider.rawValue,
                "model": value(llm.model),
                "declaredTools": llm.declaredTools.map { tool in
                    ["name": tool.name, "kind": tool.kind.rawValue, "server": value(tool.server)]
                },
                "connectors": llm.connectors.map { connector in
                    ["label": connector.label, "provider": connector.provider, "approval": value(connector.approval),
                     "allowedTools": value(connector.allowedTools), "tools": value(connector.tools),
                     "authorized": connector.authorized]
                },
                "stopReason": value(llm.stopReason),
                "errorType": value(llm.errorType),
            ]
        }
        return context
    }

    private func helperURL() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/Helpers/FlowlightResponseScriptHelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
