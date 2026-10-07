import Foundation

/// Runs one response script out of process. Any problem is deliberately indistinguishable from "no edit": the proxy
/// sends the server's original response rather than inventing an error on behalf of a diagnostic rule.
final class ResponseScriptRunner: @unchecked Sendable {
    static let shared = ResponseScriptRunner()
    static let maxScriptBytes = 128 * 1024
    static let maxPayloadBytes = ResponseGate.holdLimit
    static let timeout: TimeInterval = 0.25

    struct Result: Sendable { var body: Data; var note: String }

    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        func set(_ data: Data) { lock.lock(); value = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
    }

    private init() {}

    func transform(rules: [ResponseTransformRule], request: ResponseTransformRequest, responseHead: HTTPHead, responseBody: Data) -> Result? {
        guard responseBody.count <= Self.maxPayloadBytes,
              let representation = ResponseRepresentation.detect(headers: responseHead.headers, body: responseBody) else { return nil }
        var body = responseBody
        var names: [String] = []
        for rule in rules {
            guard rule.script.lengthOfBytes(using: .utf8) <= Self.maxScriptBytes,
                  let transformed = run(rule: rule, request: request, representation: representation, body: body),
                  transformed.count <= Self.maxPayloadBytes else { continue }
            body = transformed
            names.append(rule.title)
        }
        guard !names.isEmpty, body != responseBody else { return nil }
        return Result(body: body, note: names.joined(separator: " · "))
    }

    private func run(rule: ResponseTransformRule, request: ResponseTransformRequest, representation: ResponseRepresentation, body: Data) -> Data? {
        let input: [String: Any] = [
            "script": rule.script,
            "method": request.method,
            "url": request.url,
            "requestHeaders": request.headers,
            "representation": representation.rawValue,
            "response": representation == .json
                ? ((try? JSONSerialization.jsonObject(with: body)) as Any)
                : (String(data: body, encoding: .utf8) as Any),
        ]
        guard JSONSerialization.isValidJSONObject(input),
              let encoded = try? JSONSerialization.data(withJSONObject: input),
              encoded.count <= Self.maxPayloadBytes else { return nil }
        guard let executable = helperURL() else { return nil }
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
        // Drain stdout while the helper runs. Waiting for it to exit before reading would deadlock when a valid
        // response grows beyond a pipe buffer (the helper permits up to the transform hold limit).
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(stdout.fileHandleForReading.readDataToEndOfFile())
            outputDone.signal()
        }
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        stdin.fileHandleForWriting.write(encoded)
        try? stdin.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + Self.timeout) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 0.1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.1)
            }
            _ = outputDone.wait(timeout: .now() + 0.1)
            return nil
        }
        guard outputDone.wait(timeout: .now() + 0.1) == .success,
              process.terminationStatus == 0 else { return nil }
        let captured = output.get()
        guard captured.count <= Self.maxPayloadBytes,
              let object = try? JSONSerialization.jsonObject(with: captured) as? [String: Any],
              object["representation"] as? String == representation.rawValue,
              let value = object["response"] else { return nil }
        switch representation {
        case .json:
            guard JSONSerialization.isValidJSONObject([value]),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return data
        case .text:
            guard let text = value as? String else { return nil }
            return Data(text.utf8)
        }
    }

    private func helperURL() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let url = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Library/Helpers/FlowlightResponseScriptHelper")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
