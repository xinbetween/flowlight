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
