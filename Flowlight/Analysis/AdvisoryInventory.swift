import Foundation

/// The kinds of local software artifacts that can be assessed without sending an inventory off the Mac.
enum AdvisoryArtifactKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case application
    case executable
    case homebrewFormula
    case homebrewCask
    case nodePackage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return L("Applications")
        case .executable: return L("Executables")
        case .homebrewFormula: return L("Homebrew formulas")
        case .homebrewCask: return L("Homebrew casks")
        case .nodePackage: return L("Node packages")
        }
    }

    var systemImage: String {
        switch self {
        case .application: return "app.badge"
        case .executable: return "terminal"
        case .homebrewFormula: return "shippingbox"
        case .homebrewCask: return "macwindow"
        case .nodePackage: return "shippingbox.fill"
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

    init(kind: AdvisoryArtifactKind, identifier: String, name: String, path: String, version: String?,
         buildVersion: String? = nil, versionScheme: AdvisoryVersionScheme,
         identityEvidence: AdvisoryIdentityEvidence, versionEvidence: AdvisoryVersionEvidence?, source: String,
         iconPath: String?) {
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
    }

    /// Paths distinguish two installations with the same coordinate without changing their match identity.
    var id: String {
        "\(kind.rawValue):\(identifier.lowercased()):\(canonicalPath(path))"
    }

    var hasVersionEvidence: Bool { version != nil && versionEvidence != nil }

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
        var maximumPackageManifestBytes: Int = 1_048_576

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
        let result = InstalledApps.scan(in: configuration.applicationRoots, manager: fileManager)
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
                    let name = URL(fileURLWithPath: canonical).lastPathComponent
                    guard !name.isEmpty else { continue }
                    artifacts.append(AdvisoryArtifact(
                        kind: .executable,
                        identifier: name,
                        name: name,
                        path: canonical,
                        version: nil,
                        versionScheme: .opaque,
                        identityEvidence: .executablePath,
                        versionEvidence: nil,
                        source: L("Executable path"),
                        iconPath: canonical
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
                        guard let receipt = readHomebrewReceipt(receiptURL),
                              let name = receipt.name, let version = receipt.version else { continue }
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
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink != true else {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.lastPathComponent == "INSTALL_RECEIPT.json" else { continue }
                let receiptURL = url
                guard let receipt = readHomebrewReceipt(receiptURL),
                      let name = receipt.name, let version = receipt.version else { continue }
                let caskPath = receiptURL.deletingLastPathComponent().deletingLastPathComponent()
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

    private func readHomebrewReceipt(_ url: URL) -> (name: String?, version: String?)? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= configuration.maximumPackageManifestBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        let source = dictionary["source"] as? [String: Any]
        let specs = source?["specs"] as? [String: Any]
        let name = ((dictionary["name"] as? String) ?? (specs?["name"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = ((dictionary["version"] as? String) ?? (specs?["version"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, let version, !version.isEmpty else { return nil }
        return (name, version)
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
                if relativeDepth >= configuration.maximumProjectDepth || shouldSkipProjectDirectory(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.lastPathComponent == "package.json",
                  url.pathComponents.contains("node_modules") else { continue }
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
                iconPath: nil
            ))
        }
        let sourceComplete = complete && !bookmarkWasStale
        return (artifacts, AdvisoryInventorySourceResult(
            source: root.path, discovered: artifacts.count, complete: sourceComplete,
            detail: sourceComplete ? nil : (bookmarkWasStale
                ? L("The selected folder permission is stale; refresh it in Settings.")
                : L("The selected folder was only partially inspected."))))
    }

    private func readPackage(_ url: URL) -> (name: String?, version: String?)? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= configuration.maximumPackageManifestBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
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
