import Foundation
import JavaScriptCore

private let maxInputBytes = 4 * 1024 * 1024
private let maxScriptBytes = 128 * 1024
private let maxOutputBytes = 4 * 1024 * 1024

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= maxInputBytes,
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let script = object["script"] as? String,
      script.lengthOfBytes(using: .utf8) <= maxScriptBytes,
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
    let output: [String: Any] = ["representation": "json", "response": value]
    guard let encoded = try? JSONSerialization.data(withJSONObject: output), encoded.count <= maxOutputBytes else { fail("output too large") }
    FileHandle.standardOutput.write(encoded)
case "text":
    guard let text = value as? String, text.lengthOfBytes(using: .utf8) <= maxOutputBytes else { fail("invalid text result") }
    let output: [String: Any] = ["representation": "text", "response": text]
    guard let encoded = try? JSONSerialization.data(withJSONObject: output), encoded.count <= maxOutputBytes else { fail("output too large") }
    FileHandle.standardOutput.write(encoded)
default:
    fail("invalid representation")
}
