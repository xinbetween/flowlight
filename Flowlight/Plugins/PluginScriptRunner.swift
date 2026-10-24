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
        #if APP_STORE
        return []
        #else
        return manifests.flatMap { evaluate(exchange: exchange, manifest: $0) }
        #endif
    }

    func evaluate(exchange: HTTPExchange, manifest: PluginManifest) -> [PluginFindingDraft] {
        #if APP_STORE
        return []
        #else
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
        #endif
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
        let maySuggest = canSuggestActions(manifest)
        let actions = maySuggest ? suggestedActions(from: object["suggestedActions"], exchange: exchange) : []
        let legacyGuardrail = maySuggest ? suggestedGuardrail(from: object["suggestedGuardrail"], exchange: exchange) : nil
        let legacyRule = maySuggest ? suggestedRule(from: object["suggestedRule"], exchange: exchange) : nil
        let normalizedActions = actions.isEmpty ? legacyActions(guardrail: legacyGuardrail, rule: legacyRule) : actions
        let guardrail = legacyGuardrail ?? normalizedActions.compactMap(\.guardrail).first
        let rule = legacyRule ?? normalizedActions.compactMap(\.networkRule).first
        return PluginFindingDraft(pluginID: manifest.id, pluginVersion: manifest.version, kind: manifest.kind, severity: severity,
                                  title: title, summary: summary, evidence: evidence,
                                  suggestedGuardrail: guardrail, suggestedRule: rule, suggestedActions: normalizedActions)
    }

    private func canSuggestActions(_ manifest: PluginManifest) -> Bool {
        (manifest.capabilities.contains(.suggestAction) || manifest.capabilities.contains(.suggestGuardrail)) &&
            (manifest.permissions.contains(.suggestAction) || manifest.permissions.contains(.suggestGuardrail))
    }

    private func legacyActions(guardrail: Guardrail?, rule: Rule?) -> [PluginSuggestedAction] {
        var actions: [PluginSuggestedAction] = []
        if let guardrail { actions.append(.legacy(guardrail: guardrail)) }
        if let rule { actions.append(.legacy(rule: rule)) }
        return actions
    }

    private func suggestedActions(from value: Any?, exchange: HTTPExchange) -> [PluginSuggestedAction] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.prefix(4).compactMap { object in
            guard let kindText = object["kind"] as? String,
                  let kind = PluginSuggestedAction.Kind(rawValue: kindText) else { return nil }
            let title = limited(object["title"], fallback: defaultActionTitle(kind), count: 120)
            let reason = limited(object["reason"], fallback: L("Plugin suggested a reviewed Flowlight action."), count: 240)
            switch kind {
            case .guardrail:
                guard let guardrail = suggestedGuardrail(from: object["guardrail"], exchange: exchange) else { return nil }
                return PluginSuggestedAction(kind: kind, title: title, reason: reason, guardrail: guardrail)
            case .networkRule:
                guard let rule = suggestedRule(from: object["networkRule"], exchange: exchange) else { return nil }
                return PluginSuggestedAction(kind: kind, title: title, reason: reason, networkRule: rule)
            case .mockResponse:
                guard let mock = suggestedMock(from: object["mock"], exchange: exchange) else { return nil }
                return PluginSuggestedAction(kind: kind, title: title, reason: reason, mock: mock)
            case .requestRewrite:
                guard let rewrite = suggestedRewrite(from: object["rewrite"], exchange: exchange) else { return nil }
                return PluginSuggestedAction(kind: kind, title: title, reason: reason, rewrite: rewrite)
            case .responseTransform:
                guard let transform = suggestedResponseTransform(from: object["responseTransform"], exchange: exchange) else { return nil }
                return PluginSuggestedAction(kind: kind, title: title, reason: reason, responseTransform: transform)
            }
        }
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

    private func suggestedMock(from value: Any?, exchange: HTTPExchange) -> PluginSuggestedAction.MockSuggestion? {
        guard let object = value as? [String: Any] else { return nil }
        var suggestion = PluginSuggestedAction.MockSuggestion()
        suggestion.name = limited(object["name"], count: 120)
        suggestion.host = limited(object["host"], fallback: exchange.host, count: 240).lowercased()
        suggestion.path = limited(object["path"], fallback: pathOnly(exchange.path), count: 240)
        suggestion.method = limited(object["method"], fallback: exchange.method, count: 20).uppercased()
        suggestion.status = clampedInt(object["status"], fallback: exchange.status ?? 500, range: 100...599)
        suggestion.delay = clampedDouble(object["delay"], fallback: 0, range: 0...300)
        suggestion.headers = suggestedHeaders(from: object["headers"])
        suggestion.body = limited(object["body"], count: 4096)
        return suggestion.host.isEmpty ? nil : suggestion
    }

    private func suggestedRewrite(from value: Any?, exchange: HTTPExchange) -> PluginSuggestedAction.RewriteSuggestion? {
        guard let object = value as? [String: Any] else { return nil }
        let headers = suggestedHeaderEdits(from: object["headers"])
        let body = suggestedBodyEdits(from: object["body"])
        guard !headers.isEmpty || !body.isEmpty else { return nil }
        return PluginSuggestedAction.RewriteSuggestion(name: limited(object["name"], count: 120),
                                                       host: limited(object["host"], fallback: exchange.host, count: 240).lowercased(),
                                                       path: limited(object["path"], fallback: pathOnly(exchange.path), count: 240),
                                                       method: limited(object["method"], fallback: exchange.method, count: 20).uppercased(),
                                                       headers: headers, body: body)
    }

    private func suggestedResponseTransform(from value: Any?, exchange: HTTPExchange) -> PluginSuggestedAction.ResponseTransformSuggestion? {
        guard let object = value as? [String: Any] else { return nil }
        let script = limited(object["script"], count: 4096)
        guard !script.isEmpty else { return nil }
        return PluginSuggestedAction.ResponseTransformSuggestion(name: limited(object["name"], count: 120),
                                                                 host: limited(object["host"], fallback: exchange.host, count: 240).lowercased(),
                                                                 path: limited(object["path"], fallback: pathOnly(exchange.path), count: 240),
                                                                 method: limited(object["method"], fallback: exchange.method, count: 20).uppercased(),
                                                                 script: script)
    }

    private func suggestedHeaders(from value: Any?) -> [HTTPHeader] {
        let raw = (value as? [[String: Any]]) ?? []
        return raw.prefix(16).compactMap { object in
            let name = MockRule.headerSafe(limited(object["name"], count: 120))
            guard !name.isEmpty else { return nil }
            return HTTPHeader(name: name, value: MockRule.headerSafe(limited(object["value"], count: 240)))
        }
    }

    private func suggestedHeaderEdits(from value: Any?) -> [HeaderEdit] {
        let raw = (value as? [[String: Any]]) ?? []
        return raw.prefix(16).compactMap { object in
            let name = MockRule.headerSafe(limited(object["name"], count: 120))
            guard !name.isEmpty else { return nil }
            let op = HeaderEdit.Op(rawValue: limited(object["op"], fallback: "set", count: 20)) ?? .set
            return HeaderEdit(op: op, name: name, value: MockRule.headerSafe(limited(object["value"], count: 240)))
        }
    }

    private func suggestedBodyEdits(from value: Any?) -> [BodyEdit] {
        let raw = (value as? [[String: Any]]) ?? []
        return raw.prefix(16).compactMap { object in
            let path = limited(object["path"], count: 160)
            guard !path.isEmpty else { return nil }
            let op = BodyEdit.Op(rawValue: limited(object["op"], fallback: "set", count: 20)) ?? .set
            return BodyEdit(op: op, path: path, value: limited(object["value"], count: 4096))
        }
    }

    private func defaultActionTitle(_ kind: PluginSuggestedAction.Kind) -> String {
        switch kind {
        case .guardrail: return L("Review guardrail")
        case .networkRule: return L("Review rule")
        case .mockResponse: return L("Review mock")
        case .requestRewrite: return L("Review rewrite")
        case .responseTransform: return L("Review transform")
        }
    }

    private func pathOnly(_ path: String) -> String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    private func clampedInt(_ value: Any?, fallback: Int, range: ClosedRange<Int>) -> Int {
        min(max((value as? Int) ?? fallback, range.lowerBound), range.upperBound)
    }

    private func clampedDouble(_ value: Any?, fallback: Double, range: ClosedRange<Double>) -> Double {
        min(max((value as? Double) ?? fallback, range.lowerBound), range.upperBound)
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
