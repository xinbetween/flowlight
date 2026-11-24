import Darwin
import Foundation

/// An explicit, bounded local probe for a small set of well-known command-line tools.
///
/// Discovery remains metadata-only. This type is called only by an explicit Advisories action and never participates
/// in traffic enforcement or catalog transport. The executable path and `--version` argument are fixed by Flowlight;
/// neither the advisory catalog nor a shell can provide commands to run.
struct ExecutableVersionProbe: Sendable {
    struct Configuration: Sendable, Equatable {
        var timeout: TimeInterval = 0.35
        var terminationGrace: TimeInterval = 0.10
        var maximumOutputBytes = 16 * 1024
        var maximumProbes = 64
    }

    enum Status: Equatable, Sendable {
        case found
        case notAttempted
        case unavailable
        case nonZeroExit
        case timedOut
        case outputLimitExceeded
        case cancelled
        case invalidOutput
    }

    struct Result: Equatable, Sendable {
        var status: Status
        var version: String?

        static let notAttempted = Result(status: .notAttempted, version: nil)
    }

    struct RawResult: Sendable {
        var output: Data
        var exitCode: Int32?
        var timedOut: Bool
        var outputLimitExceeded: Bool
        var cancelled: Bool

        init(output: Data = Data(), exitCode: Int32? = nil, timedOut: Bool = false,
             outputLimitExceeded: Bool = false, cancelled: Bool = false) {
            self.output = output
            self.exitCode = exitCode
            self.timedOut = timedOut
            self.outputLimitExceeded = outputLimitExceeded
            self.cancelled = cancelled
        }
    }

    typealias Runner = @Sendable (URL, [String], Configuration) async -> RawResult
    typealias PathValidator = @Sendable (URL) -> Bool

    private let configuration: Configuration
    private let runner: Runner
    private let pathValidator: PathValidator

    /// These tools have stable, conventional `--version` behavior and are commonly found in the bounded roots.
    /// Unknown executables remain visible in the inventory but are not launched.
    private static let supportedTools: Set<String> = [
        "brew", "cargo", "curl", "docker", "ffmpeg", "gh", "git", "go", "jq", "kubectl", "node", "npm",
        "npx", "openssl", "perl", "podman", "python", "python3", "ruby", "rustc", "swift", "terraform", "wget"
    ]

    init(configuration: Configuration = Configuration(), runner: Runner? = nil,
         pathValidator: @escaping PathValidator = { url in ExecutableVersionProbe.isSafeExecutable(url) }) {
        self.configuration = configuration
        self.runner = runner ?? { url, arguments, configuration in
            await Self.runProcess(url: url, arguments: arguments, configuration: configuration)
        }
        self.pathValidator = pathValidator
    }

    var maximumProbes: Int { configuration.maximumProbes }

    static func isEligible(_ artifact: AdvisoryArtifact) -> Bool {
        artifact.kind == .executable && supportedTools.contains(artifact.identifier.lowercased())
    }

    func probe(_ artifact: AdvisoryArtifact) async -> Result {
        guard Self.isEligible(artifact) else {
            return .notAttempted
        }
        let url = URL(fileURLWithPath: artifact.path).standardizedFileURL
        guard Self.canonicalPath(url) == artifact.path, pathValidator(url) else {
            return Result(status: .unavailable, version: nil)
        }
        guard !Task.isCancelled else { return Result(status: .cancelled, version: nil) }

        let raw = await runner(url, ["--version"], configuration)
        if raw.cancelled || Task.isCancelled { return Result(status: .cancelled, version: nil) }
        if raw.outputLimitExceeded { return Result(status: .outputLimitExceeded, version: nil) }
        if raw.timedOut { return Result(status: .timedOut, version: nil) }
        guard raw.exitCode == 0 else { return Result(status: .nonZeroExit, version: nil) }
        guard let version = Self.parseVersion(from: raw.output, expectedExecutable: artifact.identifier) else {
            return Result(status: .invalidOutput, version: nil)
        }
        return Result(status: .found, version: version)
    }

    static func parseVersion(from data: Data) -> String? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        return parseVersion(from: output)
    }

    /// Parses a version only when the complete output contains one usable numeric token.
    /// This strict form is useful for simple commands such as `npm --version`.
    static func parseVersion(from output: String) -> String? {
        let versions = Set(versionMatches(in: output))
        guard versions.count == 1 else { return nil }
        return versions.first
    }

    /// Parses the primary version from a known tool's first-line banner. Some supported tools, notably curl,
    /// include dependency versions in the same banner; those are not the tool version and must not make the
    /// otherwise valid result ambiguous. The executable name is supplied by the bounded allowlist, never output.
    static func parseVersion(from data: Data, expectedExecutable: String) -> String? {
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        if let strict = parseVersion(from: output) { return strict }

        guard let firstLine = output.split(whereSeparator: { $0.isNewline }).first else { return nil }
        let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedExecutable.lowercased()
        let aliases: Set<String> = expected == "python3" ? ["python", "python3"] : [expected]
        guard let alias = aliases.first(where: { candidate in
            line.lowercased() == candidate || line.lowercased().hasPrefix(candidate + " ")
        }) else { return nil }

        let remainder = line.dropFirst(alias.count).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^version\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        return versionMatches(in: String(remainder)).first
    }

    private static func versionMatches(in output: String) -> [String] {
        let pattern = #"(?<![0-9])v?([0-9]+(?:\.[0-9]+){1,3})(?![0-9])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return expression.matches(in: output, range: range).compactMap { match -> String? in
            guard let matchRange = Range(match.range(at: 1), in: output) else { return nil }
            let value = String(output[matchRange])
            return VersionRangeMatcher.isUsable(version: value, scheme: .opaque) ? value : nil
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isSafeExecutable(_ url: URL) -> Bool {
        let canonical = canonicalPath(url)
        guard canonical == url.path else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func runProcess(url: URL, arguments: [String], configuration: Configuration) async -> RawResult {
        let processBox = ProcessBox()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<RawResult, Never>) in
                let process = Process()
                process.executableURL = url
                process.arguments = arguments
                process.environment = [:]
                process.currentDirectoryURL = URL(fileURLWithPath: "/")
                process.standardInput = FileHandle.nullDevice

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                let state = OutputState(limit: max(0, configuration.maximumOutputBytes))
                let termination = DispatchSemaphore(value: 0)
                let readers = DispatchGroup()
                process.terminationHandler = { _ in termination.signal() }
                processBox.attach(process, cancellationGrace: configuration.terminationGrace)

                do {
                    try process.run()
                    processBox.isolateProcessGroup()
                } catch {
                    continuation.resume(returning: RawResult())
                    return
                }

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { readers.leave() }
                    while true {
                        let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                        guard !chunk.isEmpty else { break }
                        if !state.append(chunk) {
                            processBox.forceKill()
                            break
                        }
                    }
                }

                DispatchQueue.global(qos: .utility).async {
                    let deadline = DispatchTime.now() + max(0.01, configuration.timeout)
                    var timedOut = false
                    if termination.wait(timeout: deadline) == .timedOut {
                        timedOut = true
                        processBox.terminate()
                        if termination.wait(timeout: .now() + max(0.01, configuration.terminationGrace)) == .timedOut {
                            processBox.forceKill()
                            _ = termination.wait(timeout: .now() + 1.0)
                        }
                    }
                    readers.wait()
                    continuation.resume(returning: RawResult(
                        output: state.data,
                        exitCode: process.terminationStatus,
                        timedOut: timedOut,
                        outputLimitExceeded: state.outputLimitExceeded,
                        cancelled: processBox.wasCancelled
                    ))
                }
            }
        }, onCancel: {
            processBox.cancel(after: configuration.terminationGrace)
        })
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isolatedProcessGroup = false
    private var cancelled = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process, cancellationGrace: TimeInterval) {
        lock.lock()
        self.process = process
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop { cancel(after: cancellationGrace) }
    }

    func cancel(after grace: TimeInterval) {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
        guard let process else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, grace)) {
            guard process.isRunning else { return }
            self.forceKill()
        }
    }

    func isolateProcessGroup() {
        lock.lock()
        guard let process, process.isRunning else {
            lock.unlock()
            return
        }
        let result = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
        isolatedProcessGroup = result == 0
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    func forceKill() {
        lock.lock()
        let process = self.process
        let shouldKillGroup = isolatedProcessGroup
        lock.unlock()
        guard let process, process.isRunning else { return }
        if shouldKillGroup {
            _ = Darwin.kill(-process.processIdentifier, SIGKILL)
        }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

private final class OutputState: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var output = Data()
    private(set) var outputLimitExceeded = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !outputLimitExceeded else { return false }
        guard output.count + data.count <= limit else {
            outputLimitExceeded = true
            return false
        }
        output.append(data)
        return true
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}
