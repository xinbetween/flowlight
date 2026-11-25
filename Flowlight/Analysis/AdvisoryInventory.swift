import Darwin
import Foundation

/// The kinds of local software artifacts that can be assessed without sending an inventory off the Mac.
enum AdvisoryArtifactKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case application
    case executable
    case homebrewFormula
    case homebrewCask
    case nodePackage
    case package

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return L("Applications")
        case .executable: return L("Executables")
        case .homebrewFormula: return L("Homebrew formulas")
        case .homebrewCask: return L("Homebrew casks")
        case .nodePackage: return L("Node packages")
        case .package: return L("Packages")
        }
    }

    var systemImage: String {
        switch self {
        case .application: return "app.badge"
        case .executable: return "terminal"
        case .homebrewFormula: return "shippingbox"
        case .homebrewCask: return "macwindow"
        case .nodePackage, .package: return "shippingbox.fill"
        }
    }

    var isPackage: Bool {
        switch self {
        case .homebrewFormula, .homebrewCask, .nodePackage, .package: return true
        case .application, .executable: return false
        }
    }
}

enum AdvisoryPackageManager: String, Codable, CaseIterable, Hashable, Sendable {
    case homebrewFormula
    case homebrewCask
    case npm
    case pip
    case cargo
    case goModules
    case bundler
    case composer
    case maven
    case gradle
    case nuget
    case swiftPM
    case mix

    var title: String {
        switch self {
        case .homebrewFormula: return L("Homebrew formula")
        case .homebrewCask: return L("Homebrew cask")
        case .npm: return L("npm package")
        case .pip: return L("PyPI package")
        case .cargo: return L("Cargo package")
        case .goModules: return L("Go module")
        case .bundler: return L("RubyGems package")
        case .composer: return L("Composer package")
        case .maven: return L("Maven package")
        case .gradle: return L("Gradle package")
        case .nuget: return L("NuGet package")
        case .swiftPM: return L("Swift package")
        case .mix: return L("Hex package")
        }
    }
}

enum AdvisoryVersionScheme: String, Codable, Hashable, Sendable {
    case numeric
    case semver
    case opaque
}

enum AdvisoryIdentityEvidence: String, Codable, Hashable, Sendable {
    case applicationBundle
    case executablePath
    case homebrewReceipt
    case packageManifest
}

enum AdvisoryVersionEvidence: String, Codable, Hashable, Sendable {
    case bundleInfoDictionary
    case homebrewInstallReceipt
    case packageJSON
    case packageMetadata
    case executableVersionProbe
}

private enum BoundedJSONReadResult {
    case dictionary([String: Any])
    case unavailable
}

private enum HomebrewReceiptReadResult {
    case receipt(name: String, version: String)
    case unavailable
}

/// A typed identity for one local software artifact. `identifier` is a catalog coordinate, not a display name.
struct AdvisoryArtifact: Equatable, Hashable, Sendable, Identifiable {
    var kind: AdvisoryArtifactKind
    var identifier: String
    var name: String
    var path: String
    var version: String?
    var buildVersion: String?
    var versionScheme: AdvisoryVersionScheme
    var identityEvidence: AdvisoryIdentityEvidence
    var versionEvidence: AdvisoryVersionEvidence?
    var source: String
    var iconPath: String?
    var packageManager: AdvisoryPackageManager?
    /// The directory-entry alias used to choose a fixed probe profile. The execution path remains `path`.
    var executionAlias: String?

    init(kind: AdvisoryArtifactKind, identifier: String, name: String, path: String, version: String?,
         buildVersion: String? = nil, versionScheme: AdvisoryVersionScheme,
         identityEvidence: AdvisoryIdentityEvidence, versionEvidence: AdvisoryVersionEvidence?, source: String,
         iconPath: String?, packageManager: AdvisoryPackageManager? = nil, executionAlias: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
        self.path = path
        self.version = version
        self.buildVersion = buildVersion
        self.versionScheme = versionScheme
        self.identityEvidence = identityEvidence
        self.versionEvidence = versionEvidence
        self.source = source
        self.iconPath = iconPath
        self.packageManager = packageManager
        self.executionAlias = executionAlias
    }

    /// Paths distinguish two installations with the same coordinate without changing their match identity.
    var id: String {
        "\(kind.rawValue):\(identifier.lowercased()):\(canonicalPath(path))"
    }

    var hasVersionEvidence: Bool {
        version != nil && versionEvidence != nil && VersionRangeMatcher.isUsable(version: version, scheme: versionScheme)
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

struct AdvisoryInventoryRoot: Equatable, Hashable, Sendable, Identifiable {
    var path: String
    var userSelected: Bool
    var bookmarkData: Data?
    var id: String { URL(fileURLWithPath: path).standardizedFileURL.path }

    init(path: String, userSelected: Bool, bookmarkData: Data? = nil) {
        self.path = path
        self.userSelected = userSelected
        self.bookmarkData = bookmarkData
    }
}

enum AdvisoryInventoryPreferences {
    static let selectedProjectRootsKey = "advisoryInventory.selectedProjectRoots"
    static let selectedProjectBookmarksKey = "advisoryInventory.selectedProjectBookmarks"

    static var selectedProjectRoots: [AdvisoryInventoryRoot] {
        let paths = UserDefaults.standard.stringArray(forKey: selectedProjectRootsKey) ?? []
        let bookmarks = UserDefaults.standard.dictionary(forKey: selectedProjectBookmarksKey) as? [String: Data] ?? [:]
        return paths.map { path in
            AdvisoryInventoryRoot(path: path, userSelected: true, bookmarkData: bookmarks[path])
        }
    }

    static func saveSelectedProjectRoots(_ roots: [AdvisoryInventoryRoot]) {
        UserDefaults.standard.set(roots.map(\.path), forKey: selectedProjectRootsKey)
        let bookmarks = Dictionary(uniqueKeysWithValues: roots.compactMap { root in
            root.bookmarkData.map { (root.path, $0) }
        })
        UserDefaults.standard.set(bookmarks, forKey: selectedProjectBookmarksKey)
    }
}

struct AdvisoryInventorySourceResult: Equatable, Sendable {
    var source: String
    var discovered: Int
    var complete: Bool
    var detail: String?
}

struct AdvisoryInventoryResult: Equatable, Sendable {
    var artifacts: [AdvisoryArtifact]
    var sources: [AdvisoryInventorySourceResult]

    var complete: Bool { sources.allSatisfy(\.complete) }
    var incompleteSources: [AdvisoryInventorySourceResult] { sources.filter { !$0.complete } }
}

/// Bounded local software discovery. It reads manifests and receipts but never executes discovered binaries.
struct AdvisoryInventoryScanner {
    struct Configuration: Equatable, Sendable {
        var applicationRoots: [String]
        var executableRoots: [String]
        var homebrewPrefixes: [String]
        var selectedProjectRoots: [AdvisoryInventoryRoot]
        var maximumProjectDepth: Int = 4
        var maximumProjectVisits: Int = 4_000
        var maximumHomebrewDepth: Int = 6
        var maximumHomebrewVisits: Int = 20_000
        var maximumPackageManifestBytes: Int = 1_048_576
        var maximumPackageArtifacts: Int = 2_000

        static var `default`: Configuration {
            let home = NSHomeDirectory()
            return Configuration(
                applicationRoots: ["/Applications", "/System/Applications", home + "/Applications"],
                executableRoots: ["/usr/bin", "/usr/local/bin", "/usr/local/sbin", "/opt/homebrew/bin", "/opt/homebrew/sbin"],
                homebrewPrefixes: ["/opt/homebrew", "/usr/local"],
                selectedProjectRoots: AdvisoryInventoryPreferences.selectedProjectRoots
            )
        }
    }

    var configuration: Configuration
    var fileManager: FileManager = .default

    init(configuration: Configuration = .default, fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    func scan() -> AdvisoryInventoryResult {
        var artifacts: [AdvisoryArtifact] = []
        var sources: [AdvisoryInventorySourceResult] = []

        let appResult = scanApplications()
        artifacts.append(contentsOf: appResult.artifacts)
        sources.append(appResult.source)

        let executableResult = scanExecutables()
        artifacts.append(contentsOf: executableResult.artifacts)
        sources.append(executableResult.source)

        let homebrewResult = scanHomebrew()
        artifacts.append(contentsOf: homebrewResult.artifacts)
        sources.append(homebrewResult.source)

        let packageResult = scanNodePackages()
        artifacts.append(contentsOf: packageResult.artifacts)
        sources.append(contentsOf: packageResult.sources)

        var unique: [String: AdvisoryArtifact] = [:]
        for artifact in artifacts {
            unique[artifact.id] = artifact
        }

        return AdvisoryInventoryResult(
            artifacts: unique.values.sorted {
                let kind = $0.kind.title.localizedCaseInsensitiveCompare($1.kind.title)
                if kind != .orderedSame { return kind == .orderedAscending }
                let name = $0.name.localizedCaseInsensitiveCompare($1.name)
                if name != .orderedSame { return name == .orderedAscending }
                return $0.id < $1.id
            },
            sources: sources
        )
    }

    private func scanApplications() -> (artifacts: [AdvisoryArtifact], source: AdvisoryInventorySourceResult) {
        let result = InstalledApps.scanAll(in: configuration.applicationRoots, manager: fileManager)
        let artifacts = result.apps.map { app in
            AdvisoryArtifact(
                kind: .application,
                identifier: app.bundleID,
                name: app.name,
                path: app.path,
                version: app.marketingVersion ?? app.buildVersion,
                buildVersion: app.buildVersion,
                versionScheme: .numeric,
                identityEvidence: .applicationBundle,
                versionEvidence: app.versionEvidence == .bundleInfoDictionary ? .bundleInfoDictionary : nil,
                source: "Application bundle",
                iconPath: app.path
            )
        }
        #if APP_STORE
        let complete = false
        let detail: String? = L("Only accessible application sources are shown.")
        #else
        let complete = configuration.applicationRoots.allSatisfy { !fileManager.fileExists(atPath: $0) } || result.complete
        let detail: String? = complete ? nil : L("Only accessible application sources are shown.")
        #endif
        return (artifacts, AdvisoryInventorySourceResult(
            source: L("Applications"), discovered: artifacts.count, complete: complete, detail: detail))
    }

    private func scanExecutables() -> (artifacts: [AdvisoryArtifact], source: AdvisoryInventorySourceResult) {
        var artifacts: [AdvisoryArtifact] = []
        var complete = true
        for root in configuration.executableRoots {
            guard fileManager.fileExists(atPath: root) else { continue }
            do {
                let urls = try fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: root),
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]),
                          values.isDirectory != true,
                          values.isRegularFile == true,
                          fileManager.isExecutableFile(atPath: url.path) else { continue }
                    let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                    let alias = url.lastPathComponent
                    guard !alias.isEmpty else { continue }
                    artifacts.append(AdvisoryArtifact(
                        kind: .executable,
                        identifier: alias,
                        name: alias,
                        path: canonical,
                        version: nil,
                        versionScheme: .opaque,
                        identityEvidence: .executablePath,
                        versionEvidence: nil,
                        source: L("Executable path"),
                        iconPath: canonical,
                        executionAlias: alias
                    ))
                }
            } catch {
                complete = false
            }
        }
        return (artifacts, AdvisoryInventorySourceResult(
            source: L("Executables"), discovered: artifacts.count, complete: complete,
            detail: complete ? nil : L("One or more executable locations could not be read.")))
    }

    private func scanHomebrew() -> (artifacts: [AdvisoryArtifact], source: AdvisoryInventorySourceResult) {
        var artifacts: [AdvisoryArtifact] = []
        var complete = true
        var seen = Set<String>()
        for prefix in configuration.homebrewPrefixes {
            let prefixURL = URL(fileURLWithPath: prefix)
            let cellar = prefixURL.appendingPathComponent("Cellar")
            if fileManager.fileExists(atPath: cellar.path) {
                guard let formulas = try? fileManager.contentsOfDirectory(
                    at: cellar, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) else {
                    complete = false
                    continue
                }
                for formula in formulas {
                    guard (try? formula.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    guard let versions = try? fileManager.contentsOfDirectory(
                        at: formula, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                    ) else { complete = false; continue }
                    for versionDirectory in versions {
                        guard (try? versionDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                        let receiptURL = versionDirectory.appendingPathComponent("INSTALL_RECEIPT.json")
                        guard fileManager.fileExists(atPath: receiptURL.path) else { continue }
                        guard case let .receipt(name, version) = readHomebrewReceipt(receiptURL) else {
                            complete = false
                            continue
                        }
                        let canonical = versionDirectory.resolvingSymlinksInPath().standardizedFileURL.path
                        let key = "formula:\(name.lowercased()):\(canonical)"
                        guard seen.insert(key).inserted else { continue }
                        artifacts.append(AdvisoryArtifact(
                            kind: .homebrewFormula,
                            identifier: name,
                            name: name,
                            path: canonical,
                            version: version,
                            versionScheme: .opaque,
                            identityEvidence: .homebrewReceipt,
                            versionEvidence: .homebrewInstallReceipt,
                            source: L("Homebrew formula receipt"),
                            iconPath: versionDirectory.appendingPathComponent("bin").path
                        ))
                    }
                }
            }

            let caskroom = prefixURL.appendingPathComponent("Caskroom")
            guard fileManager.fileExists(atPath: caskroom.path) else { continue }
            guard let enumerator = fileManager.enumerator(
                at: caskroom, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [], errorHandler: { _, _ in complete = false; return true }
            ) else { complete = false; continue }
            var visits = 0
            let caskRootDepth = caskroom.pathComponents.count
            for case let url as URL in enumerator {
                visits += 1
                if visits > configuration.maximumHomebrewVisits {
                    complete = false
                    break
                }
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isDirectory == true,
                   url.pathComponents.count - caskRootDepth >= configuration.maximumHomebrewDepth {
                    complete = false
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent == "INSTALL_RECEIPT.json" else { continue }
                let receiptURL = url
                guard case let .receipt(name, version) = readHomebrewReceipt(receiptURL) else {
                    complete = false
                    continue
                }
                let caskPath = receiptURL.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                let canonical = caskPath.resolvingSymlinksInPath().standardizedFileURL.path
                let key = "cask:\(name.lowercased()):\(canonical)"
                guard seen.insert(key).inserted else { continue }
                artifacts.append(AdvisoryArtifact(
                    kind: .homebrewCask,
                    identifier: name,
                    name: name,
                    path: canonical,
                    version: version,
                    versionScheme: .opaque,
                    identityEvidence: .homebrewReceipt,
                    versionEvidence: .homebrewInstallReceipt,
                    source: L("Homebrew cask receipt"),
                    iconPath: nil
                ))
            }
        }
        return (artifacts, AdvisoryInventorySourceResult(
            source: L("Homebrew"), discovered: artifacts.count, complete: complete,
            detail: complete ? nil : L("One or more Homebrew locations could not be read.")))
    }

    private func readHomebrewReceipt(_ url: URL) -> HomebrewReceiptReadResult {
        guard case let .dictionary(dictionary) = readBoundedJSONDictionary(url) else { return .unavailable }
        let source = dictionary["source"] as? [String: Any]
        let specs = source?["specs"] as? [String: Any]
        let name = ((dictionary["name"] as? String) ?? (specs?["name"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = ((dictionary["version"] as? String) ?? (specs?["version"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, let version, !version.isEmpty else { return .unavailable }
        return .receipt(name: name, version: version)
    }

    private func scanNodePackages() -> (artifacts: [AdvisoryArtifact], sources: [AdvisoryInventorySourceResult]) {
        var artifacts: [AdvisoryArtifact] = []
        var sources: [AdvisoryInventorySourceResult] = []
        for root in configuration.selectedProjectRoots {
            let result = scanNodePackages(in: root)
            artifacts.append(contentsOf: result.artifacts)
            sources.append(result.source)
        }
        if configuration.selectedProjectRoots.isEmpty {
            sources.append(AdvisoryInventorySourceResult(
                source: L("Selected project folders"), discovered: 0, complete: true,
                detail: L("Add a project folder in Settings to inspect node_modules.")))
        }
        return (artifacts, sources)
    }

    private func scanNodePackages(in root: AdvisoryInventoryRoot) -> (artifacts: [AdvisoryArtifact], source: AdvisoryInventorySourceResult) {
        let rootURL: URL
        var hasSecurityScope = false
        var bookmarkWasStale = false
        if let bookmarkData = root.bookmarkData {
            var isStale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil,
                                          bookmarkDataIsStale: &isStale),
                  resolved.startAccessingSecurityScopedResource() else {
                return ([], AdvisoryInventorySourceResult(source: root.path, discovered: 0, complete: false,
                                                           detail: L("The selected folder permission is unavailable.")))
            }
            rootURL = resolved.standardizedFileURL
            hasSecurityScope = true
            bookmarkWasStale = isStale
        } else {
            rootURL = URL(fileURLWithPath: root.path).standardizedFileURL
        }
        defer { if hasSecurityScope { rootURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return ([], AdvisoryInventorySourceResult(source: root.path, discovered: 0, complete: false,
                                                       detail: L("The selected folder is unavailable.")))
        }
        var artifacts: [AdvisoryArtifact] = []
        var complete = true
        var visits = 0
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in complete = false; return true }
        ) else {
            return ([], AdvisoryInventorySourceResult(source: root.path, discovered: 0, complete: false,
                                                       detail: L("The selected folder could not be read.")))
        }
        for case let url as URL in enumerator {
            visits += 1
            if visits > configuration.maximumProjectVisits {
                complete = false
                break
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                continue
            }
            let relativeDepth = url.pathComponents.count - rootURL.pathComponents.count
            if values.isDirectory == true {
                if relativeDepth >= configuration.maximumProjectDepth {
                    complete = false
                    enumerator.skipDescendants()
                } else if shouldSkipProjectDirectory(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.lastPathComponent == "package.json", url.pathComponents.contains("node_modules") {
                guard let package = readPackage(url) else {
                    complete = false
                    continue
                }
                guard let name = package.name, let version = package.version else { continue }
                let canonical = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
                artifacts.append(AdvisoryArtifact(
                    kind: .nodePackage,
                    identifier: name,
                    name: name,
                    path: canonical,
                    version: version,
                    versionScheme: .semver,
                    identityEvidence: .packageManifest,
                    versionEvidence: .packageJSON,
                    source: L("package.json"),
                    iconPath: nil,
                    packageManager: .npm
                ))
                continue
            }
            guard let manager = packageManager(for: url.lastPathComponent) else { continue }
            let discovered = readPackageArtifacts(url, manager: manager)
            if discovered.isEmpty, manager != .pip {
                complete = false
            }
            artifacts.append(contentsOf: discovered.prefix(max(0, configuration.maximumPackageArtifacts - artifacts.count)))
            if artifacts.count >= configuration.maximumPackageArtifacts {
                complete = false
                break
            }
        }
        let sourceComplete = complete && !bookmarkWasStale
        return (artifacts, AdvisoryInventorySourceResult(
            source: root.path, discovered: artifacts.count, complete: sourceComplete,
            detail: sourceComplete ? nil : (bookmarkWasStale
                ? L("The selected folder permission is stale; refresh it in Settings.")
                : L("The selected folder was only partially inspected."))))
    }

    private func packageManager(for filename: String) -> AdvisoryPackageManager? {
        switch filename {
        case "requirements.txt", "pyproject.toml": return .pip
        case "Cargo.lock": return .cargo
        case "go.mod": return .goModules
        case "Gemfile.lock": return .bundler
        case "composer.lock": return .composer
        case "pom.xml": return .maven
        case "gradle.lockfile": return .gradle
        case "packages.lock.json", "project.assets.json": return .nuget
        case "Package.resolved": return .swiftPM
        case "mix.lock": return .mix
        default: return nil
        }
    }

    private func readPackageArtifacts(_ url: URL, manager: AdvisoryPackageManager) -> [AdvisoryArtifact] {
        let text = readBoundedText(url) ?? ""
        var entries: [(String, String)] = []
        switch manager {
        case .pip:
            let pattern = #"(?m)^\s*([A-Za-z0-9_.-]+)\s*==\s*([A-Za-z0-9.+!_-]+)"#
            entries = regexPairs(text, pattern: pattern)
            if entries.isEmpty, url.lastPathComponent == "pyproject.toml" {
                if let name = regexPairs(text, pattern: #"(?m)^name\s*=\s*[\"]([^\"]+)[\"]"#).first?.0,
                   let version = regexPairs(text, pattern: #"(?m)^version\s*=\s*[\"]([^\"]+)[\"]"#).first?.1 {
                    entries = [(name, version)]
                }
            }
        case .cargo:
            entries = regexPairs(text, pattern: #"(?ms)^name\s*=\s*[\"]([^\"]+)[\"]\s*^version\s*=\s*[\"]([^\"]+)[\"]"#)
        case .goModules:
            entries = regexPairs(text, pattern: #"(?m)^\s*(?:require\s+)?([A-Za-z0-9._~/-]+)\s+v?([0-9][^\s]+)"#)
        case .bundler:
            entries = regexPairs(text, pattern: #"(?m)^\s{4}([A-Za-z0-9_.-]+) \(([^)]+)\)"#)
        case .composer:
            entries = jsonPackagePairs(url, keys: ["packages", "packages-dev"])
        case .maven:
            let groups = regexTriples(text, pattern: #"(?ms)<groupId>\s*([^<]+)\s*</groupId>.*?<artifactId>\s*([^<]+)\s*</artifactId>.*?<version>\s*([^<]+)\s*</version>"#)
            entries = groups.map { ("\($0.0):\($0.1)", $0.2) }
        case .gradle:
            entries = regexTriples(text, pattern: #"(?m)^([^:]+):([^:]+):([^=\s]+)="#).map { ("\($0.0):\($0.1)", $0.2) }
        case .nuget:
            entries = jsonPackagePairs(url, keys: ["dependencies"])
        case .swiftPM:
            entries = jsonPackagePairs(url, keys: ["pins"])
        case .mix:
            entries = regexPairs(text, pattern: #"(?m)[\"]([A-Za-z0-9_-]+)[\"]\s*:\s*\{[^}]*?[\"]([0-9]+(?:\.[0-9]+){1,3})[\"]"#)
        case .npm, .homebrewFormula, .homebrewCask:
            break
        }
        let scheme: AdvisoryVersionScheme = [.npm, .pip, .cargo, .bundler, .composer, .maven, .gradle, .nuget, .swiftPM, .mix].contains(manager) ? .semver : .opaque
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
        return entries.prefix(configuration.maximumPackageArtifacts).map { name, version in
            AdvisoryArtifact(kind: .package, identifier: name, name: name, path: canonical,
                             version: version, versionScheme: scheme, identityEvidence: .packageManifest,
                             versionEvidence: .packageMetadata, source: manager.title, iconPath: nil,
                             packageManager: manager)
        }
    }

    private func regexPairs(_ text: String, pattern: String) -> [(String, String)] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let first = Range(match.range(at: 1), in: text),
                  let second = Range(match.range(at: 2), in: text) else { return nil }
            return (String(text[first]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(text[second]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func regexTriples(_ text: String, pattern: String) -> [(String, String, String)] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges >= 4,
                  let first = Range(match.range(at: 1), in: text),
                  let second = Range(match.range(at: 2), in: text),
                  let third = Range(match.range(at: 3), in: text) else { return nil }
            return (String(text[first]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(text[second]).trimmingCharacters(in: .whitespacesAndNewlines),
                    String(text[third]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func jsonPackagePairs(_ url: URL, keys: [String]) -> [(String, String)] {
        guard case let .dictionary(root) = readBoundedJSONDictionary(url) else { return [] }
        var pairs: [(String, String)] = []
        func collect(_ value: Any) {
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let name = (item["name"] as? String) ?? (item["identity"] as? String),
                       let state = item["state"] as? [String: Any],
                       let version = state["version"] as? String {
                        pairs.append((name, version))
                    } else if let name = item["name"] as? String, let version = item["version"] as? String {
                        pairs.append((name, version))
                    }
                }
            } else if let dictionary = value as? [String: Any] {
                for (name, value) in dictionary {
                    if let version = value as? String { pairs.append((name, version)) }
                    else if let nested = value as? [String: Any], let version = nested["version"] as? String {
                        pairs.append((name, version))
                    }
                }
            }
        }
        for key in keys where root[key] != nil { collect(root[key]!) }
        return pairs
    }

    private func readBoundedText(_ url: URL) -> String? {
        let limit = configuration.maximumPackageManifestBytes
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0, (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readBoundedJSONDictionary(_ url: URL) -> BoundedJSONReadResult {
        let limit = configuration.maximumPackageManifestBytes
        guard limit >= 0 else { return .unavailable }

        // Open without following symlinks, then validate the descriptor itself. Checking the URL before
        // opening is not sufficient: a selected project or Homebrew prefix can replace a regular file
        // with a FIFO between the check and the read, which would otherwise block the scan indefinitely.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return .unavailable }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            _ = Darwin.close(descriptor)
            return .unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // Read from the already-open descriptor and request only one byte beyond the limit. This
            // keeps the memory bound valid even if a writable project or Homebrew directory replaces
            // or grows the manifest after discovery.
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return .unavailable }
            return .dictionary(dictionary)
        } catch {
            return .unavailable
        }
    }

    private func readPackage(_ url: URL) -> (name: String?, version: String?)? {
        guard case let .dictionary(dictionary) = readBoundedJSONDictionary(url) else { return nil }
        let name = (dictionary["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = (dictionary["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return nil }
        return (name, version?.isEmpty == true ? nil : version)
    }

    private func shouldSkipProjectDirectory(_ name: String) -> Bool {
        [".git", "Library", "Applications", "DerivedData", "build", "dist", ".next", "target", "vendor",
         "venv", ".venv", "Caches", "cache"].contains(name)
    }
}
