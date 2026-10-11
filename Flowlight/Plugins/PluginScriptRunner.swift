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
            "context": contextPayload(exchange),
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
        let guardrail = suggestedGuardrail(from: object["suggestedGuardrail"], exchange: exchange)
        return PluginFindingDraft(pluginID: manifest.id, pluginVersion: manifest.version, kind: manifest.kind, severity: severity,
                                  title: title, summary: summary, evidence: evidence, suggestedGuardrail: guardrail)
    }

    private func suggestedGuardrail(from value: Any?, exchange: HTTPExchange) -> Guardrail? {
        guard let object = value as? [String: Any] else { return nil }
        var guardrail = Guardrail(agent: object["agent"] as? String ?? exchange.agent ?? "",
                                  server: object["server"] as? String ?? "",
                                  tool: object["tool"] as? String ?? "",
                                  origin: .observed)
        guardrail.resource = object["resource"] as? String ?? ""
        guardrail.name = String((object["name"] as? String ?? "").prefix(120))
        return guardrail.isComplete ? guardrail : nil
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
            "configuration": manifest.configuration,
        ]
    }

    private func contextPayload(_ exchange: HTTPExchange) -> [String: Any] {
        func value<T>(_ optional: T?) -> Any { optional ?? NSNull() }
        var context: [String: Any] = [
            "method": exchange.method,
            "scheme": exchange.scheme,
            "host": exchange.host,
            "port": exchange.port,
            "path": exchange.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? exchange.path,
            "status": value(exchange.status),
            "requestHeaderNames": exchange.requestHeaders.map { $0.name },
            "responseHeaderNames": exchange.responseHeaders.map { $0.name },
            "requestSize": exchange.requestSize,
            "responseSize": exchange.responseSize,
            "requestTruncated": exchange.requestTruncated,
            "responseTruncated": exchange.responseTruncated,
            "contentType": exchange.contentType,
            "bundleID": exchange.bundleID,
            "appName": exchange.appName,
            "agent": value(exchange.agent),
            "agentName": value(exchange.agentName),
            "mcpServer": value(exchange.mcpServer),
            "toolCalls": exchange.toolCalls.map { tool in
                ["source": tool.source.rawValue, "name": tool.name, "mcpServer": value(tool.mcpServer)]
            },
            "mcp": exchange.mcp.map { activity in
                ["server": activity.server, "endpoint": activity.endpoint, "method": activity.method,
                 "tool": value(activity.tool), "tools": value(activity.tools), "version": value(activity.version),
                 "isError": activity.isError]
            },
        ]
        if let llm = exchange.llm {
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
