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

    struct MetadataVersion: Equatable {
        let version: String
        let evidence: AdvisoryVersionEvidence
    }

    /// Reads bounded version metadata without executing the file. Prefer product metadata to the
    /// linker-provided source version, which can describe an unrelated build train.
    static func metadataVersion(at url: URL, maximumBytes: Int = 1 * 1024 * 1024) -> MetadataVersion? {
        metadataVersion(at: url, maximumBytes: maximumBytes, depth: 0)
    }

    private static func metadataVersion(at url: URL, maximumBytes: Int, depth: Int) -> MetadataVersion? {
        guard depth < 2, maximumBytes > 0, let file = MetadataFile(at: url) else { return nil }
        defer { close(file.descriptor) }
        if let version = bundleVersion(at: url, maximumBytes: maximumBytes) {
            return MetadataVersion(version: version, evidence: .executableMetadata)
        }

        let headerSize = Int(min(file.size, UInt64(min(8, maximumBytes))))
        guard let header = file.read(at: 0, count: headerSize) else { return nil }
        if header.starts(with: [0x23, 0x21]) {
            let length = Int(min(file.size, UInt64(maximumBytes)))
            guard let remainder = file.read(at: UInt64(headerSize), count: length - headerSize) else { return nil }
            let data = header + remainder
            if let version = scriptVersion(in: data) {
                return MetadataVersion(version: version, evidence: .executableMetadata)
            }
            if let target = scriptTargetURL(in: data) {
                return metadataVersion(at: target, maximumBytes: maximumBytes, depth: depth + 1)
            }
            return nil
        }
        guard let version = machOSourceVersion(in: file, header: header, remainingBytes: maximumBytes - headerSize) else { return nil }
        return MetadataVersion(version: version, evidence: .machOSourceVersion)
    }

    private let configuration: Configuration
    private let runner: Runner
    private let pathValidator: PathValidator

    private enum Parser: Sendable {
        case strict
        case banner
        case regex(String)
    }

    private struct Profile: Sendable {
        var aliases: Set<String>
        var arguments: [String]
        var parser: Parser
    }

    private static let machoSourceVersionCommand: UInt32 = 0x2a
    private static let machoMagic32: UInt32 = 0xfeedface
    private static let machoMagic64: UInt32 = 0xfeedfacf
    #if arch(arm64)
    private static let preferredCPUs: [UInt32] = [0x0100000c, 0x01000007]
    #else
    private static let preferredCPUs: [UInt32] = [0x01000007, 0x0100000c]
    #endif

    private struct MetadataFile {
        let descriptor: Int32
        let size: UInt64

        init?(at url: URL) {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { return nil }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
                close(descriptor)
                return nil
            }
            self.descriptor = descriptor
            size = UInt64(info.st_size)
        }

        func read(at offset: UInt64, count: Int) -> Data? {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else { return nil }
            var data = Data(count: count)
            var copied = 0
            while copied < count {
                let length = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                    pread(descriptor, buffer.baseAddress?.advanced(by: copied), count - copied, off_t(offset + UInt64(copied)))
                }
                if length < 0, errno == EINTR { continue }
                guard length > 0 else { return nil }
                copied += length
            }
            return data
        }
    }

    private static func boundedFileData(at url: URL, maximumBytes: Int) -> Data? {
        guard let file = MetadataFile(at: url) else { return nil }
        defer { close(file.descriptor) }
        return file.read(at: 0, count: Int(min(file.size, UInt64(maximumBytes))))
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        let values = Array(bytes)
        if littleEndian {
            return UInt32(values[0]) | UInt32(values[1]) << 8 | UInt32(values[2]) << 16 | UInt32(values[3]) << 24
        }
        return UInt32(values[3]) | UInt32(values[2]) << 8 | UInt32(values[1]) << 16 | UInt32(values[0]) << 24
    }

    private static func readUInt64(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 8)]
        let values = Array(bytes)
        var result: UInt64 = 0
        if littleEndian {
            for index in 0..<8 { result |= UInt64(values[index]) << UInt64(index * 8) }
        } else {
            for index in 0..<8 { result = (result << 8) | UInt64(values[index]) }
        }
        return result
    }

    private struct MachOSlice {
        let offset: UInt64
        let size: UInt64
        let cpu: UInt32?
    }

    private static func machOSourceVersion(in file: MetadataFile, header: Data, remainingBytes: Int) -> String? {
        let fat32: UInt32 = 0xcafebabe
        let fat64: UInt32 = 0xcafebabf
        for littleEndian in [false, true] {
            if let magic = readUInt32(header, at: 0, littleEndian: littleEndian), magic == fat32 || magic == fat64 {
                return fatSourceVersion(in: file, header: header, remainingBytes: remainingBytes,
                                        littleEndian: littleEndian, is64: magic == fat64)
            }
        }
        return thinSourceVersion(in: file, slice: MachOSlice(offset: 0, size: file.size, cpu: nil),
                                 prefix: header, remainingBytes: remainingBytes)
    }

    private static func fatSourceVersion(in file: MetadataFile, header: Data, remainingBytes: Int,
                                         littleEndian: Bool, is64: Bool) -> String? {
        guard let count = readUInt32(header, at: 4, littleEndian: littleEndian), (1...32).contains(count) else { return nil }
        let entrySize = is64 ? 32 : 20
        let tableBytes = Int(count) * entrySize
        let tableEnd = UInt64(8 + tableBytes)
        guard tableBytes <= remainingBytes,
              let table = file.read(at: 8, count: tableBytes) else { return nil }
        var slices: [MachOSlice] = []
        for entry in stride(from: 0, to: tableBytes, by: entrySize) {
            let offset = is64 ? readUInt64(table, at: entry + 8, littleEndian: littleEndian)
                : readUInt32(table, at: entry + 8, littleEndian: littleEndian).map(UInt64.init)
            let size = is64 ? readUInt64(table, at: entry + 16, littleEndian: littleEndian)
                : readUInt32(table, at: entry + 12, littleEndian: littleEndian).map(UInt64.init)
            guard let offset, let size, offset >= tableEnd, offset <= file.size,
                  size >= 28, size <= file.size - offset,
                  let cpu = readUInt32(table, at: entry, littleEndian: littleEndian) else { return nil }
            slices.append(MachOSlice(offset: offset, size: size, cpu: cpu))
        }
        let orderedRanges = slices.sorted { $0.offset < $1.offset }
        guard zip(orderedRanges, orderedRanges.dropFirst()).allSatisfy({ $0.offset + $0.size <= $1.offset }),
              let selected = preferredCPUs.lazy.compactMap({ cpu in slices.first { $0.cpu == cpu } }).first ?? slices.first,
              remainingBytes - tableBytes >= 4,
              let prefix = file.read(at: selected.offset, count: 4) else { return nil }
        return thinSourceVersion(in: file, slice: selected, prefix: prefix, remainingBytes: remainingBytes - tableBytes - 4)
    }

    private static func thinSourceVersion(in file: MetadataFile, slice: MachOSlice, prefix: Data,
                                          remainingBytes: Int) -> String? {
        let littleEndian: Bool
        let magic: UInt32
        if let value = readUInt32(prefix, at: 0, littleEndian: true), value == machoMagic64 || value == machoMagic32 {
            littleEndian = true
            magic = value
        } else if let value = readUInt32(prefix, at: 0, littleEndian: false), value == machoMagic64 || value == machoMagic32 {
            littleEndian = false
            magic = value
        } else {
            return nil
        }
        let headerSize = magic == machoMagic64 ? 32 : 28
        let remainingHeaderBytes = headerSize - prefix.count
        guard UInt64(headerSize) <= slice.size, remainingHeaderBytes <= remainingBytes,
              let headerTail = file.read(at: slice.offset + UInt64(prefix.count), count: remainingHeaderBytes) else { return nil }
        let header = prefix + headerTail
        if let cpu = slice.cpu, readUInt32(header, at: 4, littleEndian: littleEndian) != cpu { return nil }
        guard let commandCount = readUInt32(header, at: 16, littleEndian: littleEndian), commandCount <= 4096,
              let commandBytes = readUInt32(header, at: 20, littleEndian: littleEndian),
              commandBytes >= commandCount * 8,
              UInt64(commandBytes) <= slice.size - UInt64(headerSize),
              Int(commandBytes) <= remainingBytes - remainingHeaderBytes,
              let commands = file.read(at: slice.offset + UInt64(headerSize), count: Int(commandBytes)) else { return nil }
        var commandOffset = 0
        var sourceVersion: UInt64?
        for _ in 0..<Int(commandCount) {
            guard commands.count - commandOffset >= 8,
                  let command = readUInt32(commands, at: commandOffset, littleEndian: littleEndian),
                  let commandSize = readUInt32(commands, at: commandOffset + 4, littleEndian: littleEndian),
                  commandSize >= 8, commandSize % (magic == machoMagic64 ? 8 : 4) == 0,
                  Int(commandSize) <= commands.count - commandOffset else { return nil }
            if command == machoSourceVersionCommand {
                guard commandSize == 16, sourceVersion == nil else { return nil }
                sourceVersion = readUInt64(commands, at: commandOffset + 8, littleEndian: littleEndian)
            }
            commandOffset += Int(commandSize)
        }
        guard commandOffset == commands.count, let sourceVersion else { return nil }
        return decodeSourceVersion(sourceVersion)
    }

    private static func decodeSourceVersion(_ packed: UInt64) -> String? {
        let components = [
            packed >> 40,
            (packed >> 30) & 0x3ff,
            (packed >> 20) & 0x3ff,
            (packed >> 10) & 0x3ff,
            packed & 0x3ff
        ]
        guard components.contains(where: { $0 != 0 }) else { return nil }
        var used = components
        while used.count > 2, used.last == 0 { used.removeLast() }
        return used.map(String.init).joined(separator: ".")
    }

    private static func scriptVersion(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let shebang = text.split(whereSeparator: \.isNewline).first,
              shebang.range(of: #"^#![ \t]*(?:/\S*/perl(?:[0-9.]+)?|/usr/bin/env[ \t]+(?:-S[ \t]+)?perl(?:[0-9.]+)?)(?:[ \t]|$)"#,
                            options: .regularExpression) != nil,
              let expression = try? NSRegularExpression(pattern: #"(?m)^[ \t]*(?:our[ \t]+)?\$VERSION\s*=\s*['\"]([0-9]+(?:\.[0-9]+){1,3})['\"]"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Resolves only a literal absolute executable target from a wrapper; it never evaluates shell syntax.
    private static func scriptTargetURL(in data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#!"),
              let expression = try? NSRegularExpression(pattern: #"(?m)^\s*(?:exec\s+)?(\/[^\s\"']+)"#),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let path = String(text[range])
        guard path.contains("/Contents/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func bundleVersion(at url: URL, maximumBytes: Int) -> String? {
        let components = url.pathComponents
        guard components.count >= 4, components.dropLast().suffix(2).elementsEqual(["Contents", "MacOS"]),
              components[components.count - 4].hasSuffix(".app") else { return nil }
        let infoURL = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = boundedFileData(at: infoURL, maximumBytes: min(maximumBytes, 64 * 1024)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return nil }
        if let executable = plist["CFBundleExecutable"] as? String, executable != url.lastPathComponent { return nil }
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let version = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty {
                return version
            }
        }
        return nil
    }

    /// Profiles are static application code: catalog data and discovered filenames never select a command or
    /// argument. Unknown executables remain visible in the inventory but are never launched.
    private static let profiles: [String: Profile] = {
        let strictNames = ["brew", "cargo", "curl", "docker", "ffmpeg", "gh", "git", "go", "jq", "node", "npm",
                           "npx", "openssl", "perl", "podman", "ruby", "rustc", "terraform"]
        var result = Dictionary(uniqueKeysWithValues: strictNames.map {
            ($0, Profile(aliases: [$0], arguments: ["--version"], parser: .strict))
        })
        result["wget"] = Profile(aliases: ["wget"], arguments: ["--version"],
                                  parser: .regex(#"(?i)GNU\s+Wget\s+v?([0-9]+(?:\.[0-9]+){1,3})"#))
        result["swift"] = Profile(aliases: ["swift"], arguments: ["--version"],
                                   parser: .regex(#"(?i)Apple\s+Swift\s+version\s+v?([0-9]+(?:\.[0-9]+){1,3})"#))
        result["kubectl"] = Profile(aliases: ["kubectl"], arguments: ["version", "--client", "--output=json"],
                                     parser: .regex(#"(?i)(?:gitVersion|clientVersion)"\s*:\s*"v?([0-9]+(?:\.[0-9]+){1,3})"#))
        result["python"] = Profile(aliases: ["python"], arguments: ["--version"], parser: .banner)
        result["python3"] = Profile(aliases: ["python3"], arguments: ["--version"], parser: .banner)
        result["pip"] = Profile(aliases: ["pip"], arguments: ["--version"], parser: .banner)
        result["pip3"] = Profile(aliases: ["pip3"], arguments: ["--version"], parser: .banner)
        return result
    }()

    init(configuration: Configuration = Configuration(), runner: Runner? = nil,
         pathValidator: @escaping PathValidator = { url in ExecutableVersionProbe.isSafeExecutable(url) }) {
        self.configuration = configuration
        self.runner = runner ?? { url, arguments, configuration in
            await Self.runProcess(url: url, arguments: arguments, configuration: configuration)
        }
        self.pathValidator = pathValidator
    }

    var maximumProbes: Int { configuration.maximumProbes }

    private static func profile(for executable: String) -> Profile? {
        let name = executable.lowercased()
        if let profile = profiles[name] { return profile }
        if name.range(of: #"^python3(?:\.[0-9]+)+$"#, options: .regularExpression) != nil { return profiles["python3"] }
        if name.range(of: #"^python(?:\.[0-9]+)+$"#, options: .regularExpression) != nil { return profiles["python"] }
        if name.range(of: #"^pip3(?:\.[0-9]+)+$"#, options: .regularExpression) != nil { return profiles["pip3"] }
        if name.range(of: #"^pip(?:\.[0-9]+)+$"#, options: .regularExpression) != nil { return profiles["pip"] }
        return nil
    }

    static func isEligible(_ artifact: AdvisoryArtifact) -> Bool {
        artifact.kind == .executable && profile(for: artifact.executionAlias ?? artifact.identifier) != nil
    }

    func probe(_ artifact: AdvisoryArtifact) async -> Result {
        let expectedExecutable = artifact.executionAlias ?? artifact.identifier
        guard let profile = Self.profile(for: expectedExecutable), artifact.kind == .executable else {
            return .notAttempted
        }
        let url = URL(fileURLWithPath: artifact.path).standardizedFileURL
        guard Self.canonicalPath(url) == artifact.path, pathValidator(url) else {
            return Result(status: .unavailable, version: nil)
        }
        guard !Task.isCancelled else { return Result(status: .cancelled, version: nil) }

        let raw = await runner(url, profile.arguments, configuration)
        if raw.cancelled || Task.isCancelled { return Result(status: .cancelled, version: nil) }
        if raw.outputLimitExceeded { return Result(status: .outputLimitExceeded, version: nil) }
        if raw.timedOut { return Result(status: .timedOut, version: nil) }
        guard raw.exitCode == 0 else { return Result(status: .nonZeroExit, version: nil) }
        guard let version = Self.parseVersion(from: raw.output, expectedExecutable: expectedExecutable) else {
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
        guard let profile = profile(for: expectedExecutable) else {
            return parseExpectedPrefixVersion(from: output, expectedExecutable: expectedExecutable)
        }
        switch profile.parser {
        case .strict:
            return parseVersion(from: output) ?? parseExpectedPrefixVersion(from: output, expectedExecutable: expectedExecutable)
        case .banner:
            return parseExpectedPrefixVersion(from: output, expectedExecutable: expectedExecutable)
        case let .regex(pattern):
            return firstVersionMatch(in: output, pattern: pattern)
        }
    }

    private static func parseExpectedPrefixVersion(from output: String, expectedExecutable: String) -> String? {
        guard let firstLine = output.split(whereSeparator: { $0.isNewline }).first else { return nil }
        let line = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedExecutable.lowercased()
        let aliases: Set<String> = {
            if expected.hasPrefix("python3") { return ["python", "python3"] }
            if expected.hasPrefix("python") { return ["python"] }
            if expected.hasPrefix("pip3") { return ["pip", "pip3"] }
            if expected.hasPrefix("pip") { return ["pip"] }
            return [expected]
        }()
        guard let alias = aliases.first(where: { candidate in
            line.lowercased() == candidate || line.lowercased().hasPrefix(candidate + " ")
        }) else { return nil }
        let remainder = line.dropFirst(alias.count).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^version\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        return versionMatches(in: String(remainder)).first
    }

    private static func firstVersionMatch(in output: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let versionRange = Range(match.range(at: 1), in: output) else { return nil }
        let version = String(output[versionRange])
        return VersionRangeMatcher.isUsable(version: version, scheme: .opaque) ? version : nil
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
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & 0o6000) == 0 else { return false }
        guard let prefix = boundedFileData(at: url, maximumBytes: 2),
              !prefix.elementsEqual([0x23, 0x21]) else { return false }
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
