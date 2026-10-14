import Foundation
import JavaScriptCore

private let maxInputBytes = 4 * 1024 * 1024
private let maxScriptBytes = 128 * 1024
private let maxOutputBytes = 4 * 1024 * 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func validScript(_ script: String) -> Bool {
    script.lengthOfBytes(using: .utf8) <= maxScriptBytes
}

func checkedOutput(_ object: [String: Any]) -> Data {
    guard JSONSerialization.isValidJSONObject(object),
          let encoded = try? JSONSerialization.data(withJSONObject: object),
          encoded.count <= maxOutputBytes else { fail("output too large") }
    return encoded
}

func runResponseTransform(_ object: [String: Any]) {
    guard let script = object["script"] as? String,
          validScript(script),
          let method = object["method"] as? String,
          let url = object["url"] as? String,
          let headers = object["requestHeaders"] as? [String: String],
          let representation = object["representation"] as? String,
          representation == "json" || representation == "text",
          let response = object["response"] else { fail("invalid input") }

    let context = JSContext()!
    context.exceptionHandler = { _, _ in }
    guard context.evaluateScript(script) != nil,
          context.exception == nil,
          let function = context.objectForKeyedSubscript("modifyResponse"),
          !function.isUndefined,
          function.isObject else { fail("modifyResponse was not defined") }

    let args = context.evaluateScript("({})")!
    args.setValue(method, forProperty: "method")
    args.setValue(url, forProperty: "url")
    args.setValue(headers, forProperty: "requestHeaders")
    if representation == "json" {
        args.setValue(response, forProperty: "responseJSON")
    } else {
        guard let text = response as? String else { fail("invalid text") }
        args.setValue(text, forProperty: "responseText")
    }
    guard let result = function.call(withArguments: [args]), context.exception == nil,
          !result.isUndefined, !result.isNull else { fail("script failed") }

    let value = result.toObject()
    switch representation {
    case "json":
        guard let value, JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: value), data.count <= maxOutputBytes else { fail("invalid JSON result") }
        FileHandle.standardOutput.write(checkedOutput(["representation": "json", "response": value]))
    case "text":
        guard let text = value as? String, text.lengthOfBytes(using: .utf8) <= maxOutputBytes else { fail("invalid text result") }
        FileHandle.standardOutput.write(checkedOutput(["representation": "text", "response": text]))
    default:
        fail("invalid representation")
    }
}

func cleanEvidence(_ value: Any?) -> [[String: String]] {
    let raw = (value as? [[String: Any]]) ?? []
    return raw.prefix(8).compactMap { item in
        guard let label = item["label"] as? String, !label.isEmpty,
              let value = item["value"] as? String, !value.isEmpty else { return nil }
        return ["label": String(label.prefix(80)), "value": String(value.prefix(240))]
    }
}

func cleanGuardrail(_ value: Any?) -> [String: String]? {
    guard let object = value as? [String: Any] else { return nil }
    let agent = object["agent"] as? String ?? ""
    let server = object["server"] as? String ?? ""
    let tool = object["tool"] as? String ?? ""
    let resource = object["resource"] as? String ?? ""
    guard !server.isEmpty || !tool.isEmpty || !resource.isEmpty else { return nil }
    return [
        "agent": String(agent.prefix(120)),
        "server": String(server.prefix(120)),
        "tool": String(tool.prefix(120)),
        "resource": String(resource.prefix(240)),
        "name": String((object["name"] as? String ?? "").prefix(120)),
    ]
}

func cleanRule(_ value: Any?) -> [String: Any]? {
    guard let object = value as? [String: Any] else { return nil }
    let action = object["action"] as? String ?? "block"
    guard action == "block" || action == "allow" else { return nil }
    let app = object["app"] as? String ?? ""
    let destination = object["destination"] as? String ?? ""
    guard !app.isEmpty || !destination.isEmpty else { return nil }
    var clean: [String: Any] = [
        "action": action,
        "app": String(app.prefix(160)),
        "destination": String(destination.prefix(240)),
        "path": String((object["path"] as? String ?? "").prefix(240)),
        "method": String((object["method"] as? String ?? "").prefix(20)),
        "name": String((object["name"] as? String ?? "").prefix(120)),
    ]
    if let status = intValue(object["status"]) { clean["status"] = min(max(status, 400), 599) }
    return clean
}

func cleanSuggestedActions(_ value: Any?) -> [[String: Any]] {
    let raw = (value as? [[String: Any]]) ?? []
    let kinds = Set(["guardrail", "networkRule", "mockResponse", "requestRewrite", "responseTransform"])
    return raw.prefix(4).compactMap { action in
        guard let kind = action["kind"] as? String, kinds.contains(kind) else { return nil }
        var clean: [String: Any] = [
            "kind": kind,
            "title": String((action["title"] as? String ?? "").prefix(120)),
            "reason": String((action["reason"] as? String ?? "").prefix(240)),
        ]
        switch kind {
        case "guardrail":
            guard let guardrail = cleanGuardrail(action["guardrail"]) else { return nil }
            clean["guardrail"] = guardrail
        case "networkRule":
            guard let rule = cleanRule(action["networkRule"]) else { return nil }
            clean["networkRule"] = rule
        case "mockResponse":
            guard let mock = cleanMock(action["mock"]) else { return nil }
            clean["mock"] = mock
        case "requestRewrite":
            guard let rewrite = cleanRewrite(action["rewrite"]) else { return nil }
            clean["rewrite"] = rewrite
        case "responseTransform":
            guard let transform = cleanResponseTransform(action["responseTransform"]) else { return nil }
            clean["responseTransform"] = transform
        default:
            return nil
        }
        return clean
    }
}

func cleanMock(_ value: Any?) -> [String: Any]? {
    guard let object = value as? [String: Any] else { return nil }
    let host = object["host"] as? String ?? ""
    guard !host.isEmpty else { return nil }
    return [
        "name": String((object["name"] as? String ?? "").prefix(120)),
        "host": String(host.prefix(240)),
        "path": String((object["path"] as? String ?? "").prefix(240)),
        "method": String((object["method"] as? String ?? "").prefix(20)),
        "status": min(max(intValue(object["status"]) ?? 500, 100), 599),
        "delay": min(max(doubleValue(object["delay"]) ?? 0, 0), 300),
        "headers": cleanHeaders(object["headers"]),
        "body": String((object["body"] as? String ?? "").prefix(4096)),
    ]
}

func cleanRewrite(_ value: Any?) -> [String: Any]? {
    guard let object = value as? [String: Any] else { return nil }
    let headers = cleanHeaderEdits(object["headers"])
    let body = cleanBodyEdits(object["body"])
    guard !headers.isEmpty || !body.isEmpty else { return nil }
    return [
        "name": String((object["name"] as? String ?? "").prefix(120)),
        "host": String((object["host"] as? String ?? "").prefix(240)),
        "path": String((object["path"] as? String ?? "").prefix(240)),
        "method": String((object["method"] as? String ?? "").prefix(20)),
        "headers": headers,
        "body": body,
    ]
}

func cleanResponseTransform(_ value: Any?) -> [String: String]? {
    guard let object = value as? [String: Any], let script = object["script"] as? String, !script.isEmpty else { return nil }
    return [
        "name": String((object["name"] as? String ?? "").prefix(120)),
        "host": String((object["host"] as? String ?? "").prefix(240)),
        "path": String((object["path"] as? String ?? "").prefix(240)),
        "method": String((object["method"] as? String ?? "").prefix(20)),
        "script": String(script.prefix(4096)),
    ]
}

func cleanHeaders(_ value: Any?) -> [[String: String]] {
    let raw = (value as? [[String: Any]]) ?? []
    return raw.prefix(16).compactMap { header in
        guard let name = header["name"] as? String, !name.isEmpty else { return nil }
        return ["name": String(name.prefix(120)), "value": String((header["value"] as? String ?? "").prefix(240))]
    }
}

func cleanHeaderEdits(_ value: Any?) -> [[String: String]] {
    let raw = (value as? [[String: Any]]) ?? []
    let ops = Set(["set", "add", "remove"])
    return raw.prefix(16).compactMap { edit in
        guard let name = edit["name"] as? String, !name.isEmpty else { return nil }
        let op = edit["op"] as? String ?? "set"
        guard ops.contains(op) else { return nil }
        return ["op": op, "name": String(name.prefix(120)), "value": String((edit["value"] as? String ?? "").prefix(240))]
    }
}

func cleanBodyEdits(_ value: Any?) -> [[String: String]] {
    let raw = (value as? [[String: Any]]) ?? []
    let ops = Set(["set", "remove"])
    return raw.prefix(16).compactMap { edit in
        guard let path = edit["path"] as? String, !path.isEmpty else { return nil }
        let op = edit["op"] as? String ?? "set"
        guard ops.contains(op) else { return nil }
        return ["op": op, "path": String(path.prefix(160)), "value": String((edit["value"] as? String ?? "").prefix(4096))]
    }
}

func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    return nil
}

func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    return nil
}

func runPlugin(_ object: [String: Any]) {
    guard let script = object["script"] as? String,
          validScript(script),
          let manifest = object["manifest"] as? [String: Any],
          let contextPayload = object["context"] as? [String: Any] else { fail("invalid plugin input") }

    let context = JSContext()!
    context.exceptionHandler = { _, _ in }
    guard context.evaluateScript(script) != nil,
          context.exception == nil,
          let function = context.objectForKeyedSubscript("evaluate"),
          !function.isUndefined,
          function.isObject else { fail("evaluate was not defined") }

    let args = context.evaluateScript("({})")!
    args.setValue(manifest, forProperty: "manifest")
    args.setValue(contextPayload, forProperty: "exchange")
    guard let result = function.call(withArguments: [args]), context.exception == nil,
          !result.isUndefined, !result.isNull else { fail("plugin failed") }
    let rawFindings = result.toObject() as? [[String: Any]] ?? []
    let severities = Set(["info", "low", "medium", "high"])
    let findings: [[String: Any]] = rawFindings.prefix(8).compactMap { finding in
        guard let severity = finding["severity"] as? String, severities.contains(severity),
              let title = finding["title"] as? String, !title.isEmpty, title.count <= 120,
              let summary = finding["summary"] as? String, !summary.isEmpty, summary.count <= 500 else { return nil }
        var clean: [String: Any] = [
            "severity": severity,
            "title": title,
            "summary": summary,
            "evidence": cleanEvidence(finding["evidence"]),
        ]
        if let guardrail = cleanGuardrail(finding["suggestedGuardrail"]) {
            clean["suggestedGuardrail"] = guardrail
        }
        if let rule = cleanRule(finding["suggestedRule"]) {
            clean["suggestedRule"] = rule
        }
        let actions = cleanSuggestedActions(finding["suggestedActions"])
        if !actions.isEmpty {
            clean["suggestedActions"] = actions
        }
        return clean
    }
    FileHandle.standardOutput.write(checkedOutput(["findings": findings]))
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= maxInputBytes,
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { fail("invalid input") }

if object["mode"] as? String == "plugin" {
    runPlugin(object)
} else {
    runResponseTransform(object)
}
