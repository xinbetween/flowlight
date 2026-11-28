import XCTest
@testable import Flowlight

final class AdvisoryInventoryTests: XCTestCase {
    func testBoundedScannerDiscoversTypedArtifactsWithoutExecutingBinaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-inventory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Apps/Example.app/Contents")
        let executable = root.appendingPathComponent("bin/curl")
        let formula = root.appendingPathComponent("brew/Cellar/curl/8.10.1/INSTALL_RECEIPT.json")
        let cask = root.appendingPathComponent("brew/Caskroom/wget/1.0/.metadata/receipt/INSTALL_RECEIPT.json")
        let package = root.appendingPathComponent("project/node_modules/curl/package.json")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: formula.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cask.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.Example",
            "CFBundleName": "Example",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("{\"source\":{\"specs\":{\"name\":\"curl\",\"version\":\"8.10.1\"}}}".utf8).write(to: formula)
        try Data("{\"name\":\"wget\",\"version\":\"1.0\"}".utf8).write(to: cask)
        try Data("{\"name\":\"curl\",\"version\":\"1.0.0\"}".utf8).write(to: package)

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [root.appendingPathComponent("Apps").path],
            executableRoots: [root.appendingPathComponent("bin").path],
            homebrewPrefixes: [root.appendingPathComponent("brew").path],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.appendingPathComponent("project").path, userSelected: true)]
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()

        XCTAssertEqual(result.artifacts.filter { $0.kind == .application }.map(\.identifier), ["com.example.Example"])
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .application })?.version, "1.2.3")
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .application })?.buildVersion, "42")
        XCTAssertEqual(result.artifacts.filter { $0.kind == .executable }.map(\.identifier), ["curl"])
        XCTAssertEqual(result.artifacts.filter { $0.kind == .homebrewFormula }.map(\.identifier), ["curl"])
        XCTAssertEqual(result.artifacts.filter { $0.kind == .homebrewCask }.map(\.identifier), ["wget"])
        XCTAssertEqual(result.artifacts.filter { $0.kind == .nodePackage }.map(\.identifier), ["curl"])
        XCTAssertNil(result.artifacts.first(where: { $0.kind == .executable })?.version)
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .homebrewFormula })?.versionEvidence, .homebrewInstallReceipt)
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .nodePackage })?.versionEvidence, .packageJSON)
        XCTAssertEqual(Set(result.artifacts.map(\.kind)).count, 5)
    }

    func testApplicationCopiesWithSameBundleIDRemainSeparateForAdvisories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-inventory-copies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = [root.appendingPathComponent("A/Example.app/Contents"), root.appendingPathComponent("B/Example.app/Contents")]
        for (index, contents) in paths.enumerated() {
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.example.Duplicate", "CFBundleName": "Example \(index)", "CFBundleShortVersionString": "\(index + 1).0.0"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [root.path], executableRoots: [], homebrewPrefixes: [], selectedProjectRoots: []
        )
        let apps = AdvisoryInventoryScanner(configuration: config).scan().artifacts.filter { $0.kind == .application }

        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(Set(apps.map(\.identifier)), ["com.example.Duplicate"])
        XCTAssertEqual(Set(apps.compactMap(\.version)), ["1.0.0", "2.0.0"])
    }

    func testScannerDoesNotTreatCellarDirectoryNameAsVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-inventory-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("Cellar/tool/9.9.9/INSTALL_RECEIPT.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"tool\"}".utf8).write(to: receipt)

        let config = AdvisoryInventoryScanner.Configuration(applicationRoots: [], executableRoots: [], homebrewPrefixes: [root.path], selectedProjectRoots: [])
        let result = AdvisoryInventoryScanner(configuration: config).scan()

        XCTAssertTrue(result.artifacts.filter { $0.kind == .homebrewFormula }.isEmpty)
    }

    func testSelectedProjectTraversalReportsMalformedManifestAsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-inventory-project-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let packageDirectory = root.appendingPathComponent("node_modules/example")
        let malformed = root.appendingPathComponent("node_modules/broken/package.json")
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: malformed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"example\",\"version\":\"2.0.0\"}".utf8).write(to: packageDirectory.appendingPathComponent("package.json"))
        try Data("not json".utf8).write(to: malformed)

        let config = AdvisoryInventoryScanner.Configuration(applicationRoots: [], executableRoots: [], homebrewPrefixes: [], selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)])
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let source = try XCTUnwrap(result.sources.first(where: { $0.source == root.path }))

        XCTAssertEqual(result.artifacts.filter { $0.kind == .nodePackage }.map(\.identifier), ["example"])
        XCTAssertFalse(source.complete)
        XCTAssertFalse(result.complete)
    }

    func testPackageScanDoesNotFollowDirectoryManifestOrRootSymlinks() throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("advisory-package-links-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temp) }
        let root = temp.appendingPathComponent("project")
        let outside = temp.appendingPathComponent("outside")
        let outsidePackage = outside.appendingPathComponent("node_modules/outside-package")
        let insidePackage = root.appendingPathComponent("node_modules/inside-package")
        let linkedPackage = root.appendingPathComponent("node_modules/linked-manifest")
        for directory in [outsidePackage, insidePackage, linkedPackage] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let outsideManifest = outsidePackage.appendingPathComponent("package.json")
        try Data(#"{"name":"outside-package","version":"1.0.0"}"#.utf8).write(to: outsideManifest)
        try Data(#"{"name":"inside-package","version":"1.0.0"}"#.utf8).write(to: insidePackage.appendingPathComponent("package.json"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("linked-tree"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: linkedPackage.appendingPathComponent("package.json"), withDestinationURL: outsideManifest)
        let outsideRequirements = outside.appendingPathComponent("requirements.txt")
        try Data("linked-package==1.0.0\n".utf8).write(to: outsideRequirements)
        try manager.createSymbolicLink(at: root.appendingPathComponent("requirements.txt"), withDestinationURL: outsideRequirements)
        let linkedRoot = temp.appendingPathComponent("linked-root")
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [root, linkedRoot].map { AdvisoryInventoryRoot(path: $0.path, userSelected: true) }
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()

        XCTAssertEqual(result.artifacts.map(\.identifier), ["inside-package"])
        XCTAssertFalse(try XCTUnwrap(result.sources.first { $0.source == root.path }).complete)
        let linkedSource = try XCTUnwrap(result.sources.first { $0.source == linkedRoot.path })
        XCTAssertFalse(linkedSource.complete)
        XCTAssertEqual(linkedSource.discovered, 0)
    }

    func testProjectAndHomeEntryBudgetsCountHiddenAndIrrelevantFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("advisory-wide-directory-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<80 {
            let name = index.isMultiple(of: 2) ? ".hidden-\(index)" : "unrelated-\(index).txt"
            try Data().write(to: root.appendingPathComponent(name))
        }
        var config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)],
            maximumProjectEntries: 3, maximumHomeEntries: 3
        )
        func complete(_ source: String) throws -> Bool {
            let result = AdvisoryInventoryScanner(configuration: config).scan()
            return try XCTUnwrap(result.sources.first { $0.source == source }).complete
        }

        XCTAssertFalse(try complete(root.path))
        config.maximumProjectEntries = 80
        XCTAssertTrue(try complete(root.path))
        config.selectedProjectRoots = []
        config.homePackageRoot = root.path
        XCTAssertFalse(try complete(L("Home folder")))
        config.maximumHomeEntries = 80
        XCTAssertTrue(try complete(L("Home folder")))
    }

    func testNodePackageArtifactsRespectTheAggregateCapAndReportIncompleteSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-node-cap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<4 {
            let manifest = root.appendingPathComponent("node_modules/package-\(index)/package.json")
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"name\":\"package-\(index)\",\"version\":\"1.0.\(index)\"}".utf8).write(to: manifest)
        }

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)],
            maximumPackageArtifacts: 2
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let source = try XCTUnwrap(result.sources.first(where: { $0.source == root.path }))

        XCTAssertEqual(result.artifacts.filter { $0.kind == .nodePackage }.count, 2)
        XCTAssertFalse(source.complete)
        XCTAssertFalse(result.complete)
    }

    func testHomeScanRecursivelyFindsHomePackagesAndSkipsGeneratedTrees() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-home-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let visible = home.appendingPathComponent("workspace/node_modules/home-package/package.json")
        let selected = home.appendingPathComponent("project/node_modules/selected-package/package.json")
        let protectedPackage = home.appendingPathComponent("Documents/node_modules/private-package/package.json")
        let hiddenPackage = home.appendingPathComponent(".hidden/node_modules/hidden-package/package.json")
        let generatedPackage = home.appendingPathComponent("build/node_modules/generated-package/package.json")
        for url in [visible, selected, protectedPackage, hiddenPackage, generatedPackage] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"name\":\"\(url.deletingLastPathComponent().lastPathComponent)\",\"version\":\"1.0.0\"}".utf8).write(to: url)
        }

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: home.appendingPathComponent("project").path, userSelected: true)],
            homePackageRoot: home.path,
            maximumHomeDepth: 8,
            maximumHomeVisits: 500,
            maximumHomePackageArtifacts: 50
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let packages = result.artifacts.filter { $0.kind == .nodePackage }

        XCTAssertEqual(Set(packages.map(\.identifier)), Set(["home-package", "selected-package", "private-package"]))
        XCTAssertEqual(packages.filter { $0.identifier == "selected-package" }.count, 1)
        let homeSource = try XCTUnwrap(result.sources.first(where: { $0.source == L("Home folder") }))
        XCTAssertTrue(homeSource.complete)
        XCTAssertTrue(homeSource.detail?.contains("depth 8") == true)
    }

    func testHomeScanRespectsIndependentDepthAndArtifactCaps() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-home-caps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0..<4 {
            let manifest = home.appendingPathComponent("level-\(index)/node_modules/package-\(index)/package.json")
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"name\":\"package-\(index)\",\"version\":\"1.0.\(index)\"}".utf8).write(to: manifest)
        }

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [], selectedProjectRoots: [],
            homePackageRoot: home.path,
            maximumHomeDepth: 2,
            maximumHomeVisits: 500,
            maximumHomePackageArtifacts: 1
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let source = try XCTUnwrap(result.sources.first(where: { $0.source == L("Home folder") }))

        XCTAssertLessThanOrEqual(result.artifacts.filter { $0.kind == .nodePackage }.count, 1)
        XCTAssertFalse(source.complete)
    }

    func testHomeScanPreferenceDefaultsToEnabledAndRoundTripsWithoutChangingSelectedRoots() {
        let defaults = UserDefaults.standard
        let enabledKey = AdvisoryInventoryPreferences.homeScanEnabledKey
        let rootsKey = AdvisoryInventoryPreferences.selectedProjectRootsKey
        let bookmarksKey = AdvisoryInventoryPreferences.selectedProjectBookmarksKey
        let oldEnabled = defaults.object(forKey: enabledKey)
        let oldRoots = defaults.object(forKey: rootsKey)
        let oldBookmarks = defaults.object(forKey: bookmarksKey)
        defer {
            if let oldEnabled { defaults.set(oldEnabled, forKey: enabledKey) } else { defaults.removeObject(forKey: enabledKey) }
            if let oldRoots { defaults.set(oldRoots, forKey: rootsKey) } else { defaults.removeObject(forKey: rootsKey) }
            if let oldBookmarks { defaults.set(oldBookmarks, forKey: bookmarksKey) } else { defaults.removeObject(forKey: bookmarksKey) }
        }

        defaults.removeObject(forKey: enabledKey)
        XCTAssertTrue(AdvisoryInventoryPreferences.homeScanEnabled)
        AdvisoryInventoryPreferences.setHomeScanEnabled(false)
        XCTAssertFalse(AdvisoryInventoryPreferences.homeScanEnabled)
        AdvisoryInventoryPreferences.setHomeScanEnabled(true)
        XCTAssertTrue(AdvisoryInventoryPreferences.homeScanEnabled)
    }

    func testPyProjectStaticProjectMetadataUsesPEP440Evidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-pyproject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pyproject = """
        [tool.other]
        name = "wrong-name"
        version = "9.9.9"

        [project]
        version = "1.0b11"
        name = "example-python"
        """
        try Data(pyproject.utf8).write(to: root.appendingPathComponent("pyproject.toml"))

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)]
        )
        let packages = AdvisoryInventoryScanner(configuration: config).scan().artifacts.filter { $0.kind == .package }
        let package = try XCTUnwrap(packages.first(where: { $0.identifier == "example-python" }))
        XCTAssertEqual(package.version, "1.0b11")
        XCTAssertEqual(package.versionScheme, .pep440)
        XCTAssertTrue(package.hasVersionEvidence)
    }

    func testSelectedProjectScanExtractsBoundedMetadataForSupportedPackageManagers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-package-adapters-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files: [String: String] = [
            "requirements.txt": "requests==2.32.3\n",
            "Cargo.lock": "[[package]]\nname = \"serde\"\nversion = \"1.0.210\"\n",
            "go.mod": "module example.com/tool\n\nrequire github.com/example/dep v1.2.3\n",
            "Gemfile.lock": "GEM\n  specs:\n    rack (3.1.8)\n",
            "composer.lock": "{\"packages\":[{\"name\":\"vendor/pkg\",\"version\":\"1.2.3\"}]}",
            "pom.xml": "<project><groupId>com.example</groupId><artifactId>demo</artifactId><version>1.2.3</version></project>",
            "gradle.lockfile": "com.example:demo:1.2.3=runtimeClasspath\n",
            "packages.lock.json": "{\"version\":1,\"dependencies\":{\"Example.Package\":{\"type\":\"Transitive\",\"version\":\"1.2.3\"}}}",
            "Package.resolved": "{\"pins\":[{\"identity\":\"swift-log\",\"state\":{\"version\":\"1.5.4\"}}]}",
            "mix.lock": "%{\"plug\": {:hex, :plug, \"1.16.1\", \"sha256\", \"checksum\", []}}"
        ]
        for (name, contents) in files {
            try Data(contents.utf8).write(to: root.appendingPathComponent(name))
        }

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)]
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let packages = result.artifacts.filter { $0.kind == .package }

        XCTAssertEqual(Set(packages.compactMap(\.packageManager)), Set([
            .pip, .cargo, .goModules, .bundler, .composer, .maven, .gradle, .nuget, .swiftPM, .mix
        ]))
        XCTAssertTrue(packages.contains { $0.identifier == "requests" && $0.version == "2.32.3" && $0.hasVersionEvidence })
        XCTAssertTrue(packages.contains { $0.identifier == "github.com/example/dep" && $0.version == "1.2.3" && $0.versionScheme == .goModule && $0.hasVersionEvidence })
        XCTAssertTrue(result.sources.first?.complete == true)
    }

    func testSameNameAcrossKindsHasDistinctStableIDs() throws {
        let artifacts = [
            AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: "/usr/bin/curl", version: nil, versionScheme: .opaque, identityEvidence: .executablePath, versionEvidence: nil, source: "Executable path", iconPath: nil),
            AdvisoryArtifact(kind: .homebrewFormula, identifier: "curl", name: "curl", path: "/opt/homebrew/Cellar/curl/1", version: "1", versionScheme: .opaque, identityEvidence: .homebrewReceipt, versionEvidence: .homebrewInstallReceipt, source: "Homebrew", iconPath: nil),
            AdvisoryArtifact(kind: .nodePackage, identifier: "curl", name: "curl", path: "/tmp/node_modules/curl", version: "1.0.0", versionScheme: .semver, identityEvidence: .packageManifest, versionEvidence: .packageJSON, source: "package.json", iconPath: nil),
        ]

        XCTAssertEqual(Set(artifacts.map(\.id)).count, 3)
    }

    func testExecutableVersionOutputRequiresOneUsableNumericToken() {
        XCTAssertEqual(ExecutableVersionProbe.parseVersion(from: "curl 8.10.1\n"), "8.10.1")
        XCTAssertEqual(ExecutableVersionProbe.parseVersion(from: "v2.43.0"), "2.43.0")
        XCTAssertNil(ExecutableVersionProbe.parseVersion(from: "tool version unknown"))
        XCTAssertNil(ExecutableVersionProbe.parseVersion(from: "tool 1.2.3 and library 4.5.6"))
    }

    func testKnownExecutableProfilesParseToolSpecificBanners() {
        XCTAssertEqual(
            ExecutableVersionProbe.parseVersion(from: Data("GNU Wget 1.21.4 built on darwin\n".utf8), expectedExecutable: "wget"),
            "1.21.4"
        )
        XCTAssertEqual(
            ExecutableVersionProbe.parseVersion(from: Data("Apple Swift version 6.0.2 (swift-6.0.2-RELEASE)\n".utf8), expectedExecutable: "swift"),
            "6.0.2"
        )
        XCTAssertEqual(
            ExecutableVersionProbe.parseVersion(from: Data("{\"clientVersion\":{\"gitVersion\":\"v1.30.2\"}}\n".utf8), expectedExecutable: "kubectl"),
            "1.30.2"
        )
        XCTAssertEqual(
            ExecutableVersionProbe.parseVersion(from: Data("Python 3.13.0\n".utf8), expectedExecutable: "python3.13"),
            "3.13.0"
        )
        XCTAssertEqual(
            ExecutableVersionProbe.parseVersion(from: Data("pip 24.2 from /tmp/site-packages (python 3.13)\n".utf8), expectedExecutable: "pip3.13"),
            "24.2"
        )
    }

    func testExecutableVersionProbeIsExplicitAndAddsEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("curl")
        try Data("not executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: executable.standardizedFileURL.path,
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: executable.path)
        let recorder = ProbeRecorder()
        let probe = ExecutableVersionProbe(
            runner: { url, arguments, _ in
                recorder.record(url: url.path, arguments: arguments)
                return ExecutableVersionProbe.RawResult(output: Data("curl 8.10.1\n".utf8), exitCode: 0)
            },
            pathValidator: { _ in true }
        )

        let result = await probe.probe(artifact)

        XCTAssertEqual(result, .init(status: .found, version: "8.10.1"))
        XCTAssertEqual(recorder.path, executable.standardizedFileURL.path)
        XCTAssertEqual(recorder.arguments, ["--version"])
        var enriched = artifact
        if result.status == .found {
            enriched.version = result.version
            enriched.versionEvidence = .executableVersionProbe
        }
        XCTAssertTrue(enriched.hasVersionEvidence)
        XCTAssertEqual(enriched.id, artifact.id)
    }

    func testProbeUsesCanonicalExecutablePathWithDirectoryAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-probe-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("curl-real")
        try Data("not executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = ProbeRecorder()
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: executable.standardizedFileURL.path,
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: executable.path,
                                        executionAlias: "curl")
        let probe = ExecutableVersionProbe(
            runner: { url, arguments, _ in
                recorder.record(url: url.path, arguments: arguments)
                return ExecutableVersionProbe.RawResult(output: Data("curl 8.10.1\n".utf8), exitCode: 0)
            },
            pathValidator: { $0.path == executable.standardizedFileURL.path }
        )

        let result = await probe.probe(artifact)

        XCTAssertEqual(result, .init(status: .found, version: "8.10.1"))
        XCTAssertEqual(recorder.path, executable.standardizedFileURL.path)
        XCTAssertEqual(recorder.arguments, ["--version"])
    }

    func testDefaultProbeCanReadAKnownSystemExecutableVersion() async throws {
        let path = "/usr/bin/curl"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path))
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: path,
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: path)
        let probe = ExecutableVersionProbe(configuration: .init(timeout: 2.0))

        let result = await probe.probe(artifact)

        XCTAssertEqual(result.status, .found)
        XCTAssertNotNil(result.version)
    }

    func testDefaultProbeTimesOutWithoutWaitingForChildProcesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-probe-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("curl")
        try Data("#!/bin/sh\n/bin/sleep 5\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: executable.path,
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: executable.path)
        let probe = ExecutableVersionProbe(configuration: .init(timeout: 0.05, terminationGrace: 0.05), pathValidator: { _ in true })
        let started = Date()

        let result = await probe.probe(artifact)

        XCTAssertEqual(result.status, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    func testUnsupportedExecutableIsNotLaunched() async throws {
        let recorder = ProbeRecorder()
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "custom-tool", name: "custom-tool", path: "/usr/bin/custom-tool",
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: nil)
        let probe = ExecutableVersionProbe(
            runner: { _, _, _ in
                recorder.record(url: "unexpected", arguments: [])
                return ExecutableVersionProbe.RawResult(output: Data("1.0.0".utf8), exitCode: 0)
            },
            pathValidator: { _ in true }
        )

        let result = await probe.probe(artifact)

        XCTAssertEqual(result, .notAttempted)
        XCTAssertNil(recorder.path)
    }

    func testExecutableMetadataReadsMachOSourceAndPerlVersionsWithoutExecuting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-executable-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let macho = root.appendingPathComponent("native-tool")
        let script = root.appendingPathComponent("script-tool")
        try thinMachO(sourceVersion: (6, 0, 2)).write(to: macho)
        try Data("#!/usr/bin/perl\nour $VERSION = '1.125'; # VERSION\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: macho), .init(version: "6.0.2", evidence: .machOSourceVersion))
        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: script), .init(version: "1.125", evidence: .executableMetadata))

        let shellScript = root.appendingPathComponent("shell-tool")
        try Data("#!/bin/sh\n$VERSION = '1.125'\n".utf8).write(to: shellScript)
        XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: shellScript))
    }

    func testExecutableMetadataReadsFatMachOSliceAndRejectsMalformedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-fat-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fat = root.appendingPathComponent("fat-tool")
        let malformed = root.appendingPathComponent("malformed-tool")
        try fatMachO(sourceVersion: (37, 0, 0)).write(to: fat)
        try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1]).write(to: malformed)

        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: fat), .init(version: "37.0", evidence: .machOSourceVersion))
        XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: malformed))
    }

    func testFatMachOMetadataUsesPreferredSparseSliceWithinReadBudget() throws {
        #if arch(arm64)
        let preferred: UInt32 = 0x0100000c
        let other: UInt32 = 0x01000007
        #else
        let preferred: UInt32 = 0x01000007
        let other: UInt32 = 0x0100000c
        #endif
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("advisory-sparse-fat-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let preferredHeader = thinMachO(sourceVersion: (2048, 2, 3), cpu: preferred)
        let otherHeader = thinMachO(sourceVersion: (9, 9, 9), cpu: other)
        let otherOffset: UInt64 = 4096
        let sliceSize: UInt64 = 2 * 1024 * 1024
        for is64 in [false, true] {
            let preferredOffset: UInt64 = is64 ? 1 << 32 : 4 * 1024 * 1024
            let fat = root.appendingPathComponent(is64 ? "fat64" : "fat32")
            let table = fatTable(is64: is64, slices: [
                (other, otherOffset, UInt64(otherHeader.count)), (preferred, preferredOffset, sliceSize),
            ])
            try table.write(to: fat)
            let file = try FileHandle(forWritingTo: fat)
            defer { try? file.close() }
            try file.seek(toOffset: otherOffset)
            try file.write(contentsOf: otherHeader)
            try file.seek(toOffset: preferredOffset)
            try file.write(contentsOf: preferredHeader)
            try file.truncate(atOffset: preferredOffset + sliceSize)

            let bytes = table.count + preferredHeader.count
            XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: fat, maximumBytes: bytes),
                           .init(version: "2048.2.3", evidence: .machOSourceVersion))
            XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: fat, maximumBytes: bytes - 1))
        }
    }

    func testFatMachOMetadataRejectsOutOfBoundsSlicesAndTruncatedSourceCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-fat-ranges-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fat = root.appendingPathComponent("fat-tool")
        let cpu: UInt32 = 0x0100000c
        let offset = 0x100
        let header = thinMachO(sourceVersion: (1, 2, 3), cpu: cpu)
        func write(_ slice: Data, size: UInt64, declaredOffset: UInt64? = nil) throws {
            var data = fatTable(is64: true, slices: [(cpu, declaredOffset ?? UInt64(offset), size)])
            data.append(Data(count: offset - data.count))
            data.append(slice)
            try data.write(to: fat)
        }
        for size in [UInt64(28), 40, UInt64(header.count) + 1, UInt64.max] {
            try write(header, size: size)
            XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: fat), "Invalid FAT slice size \(size)")
        }
        for invalidOffset in [UInt64(8), UInt64(Int64.max) + 1, UInt64.max] {
            try write(header, size: UInt64(header.count), declaredOffset: invalidOffset)
            XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: fat), "Invalid FAT slice offset \(invalidOffset)")
        }
        var shortCommand = header
        shortCommand.replaceSubrange(20..<24, with: littleEndian(UInt32(8))) // sizeofcmds
        shortCommand.replaceSubrange(36..<40, with: littleEndian(UInt32(8))) // cmdsize
        try write(shortCommand, size: UInt64(shortCommand.count))
        XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: fat))
    }

    func testExecutableMetadataReadsLiteralBundleWrapperTargetWithoutExecutingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-wrapper-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Example.app/Contents")
        let wrapper = root.appendingPathComponent("bin/example-wrapper")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "7.1.10", "CFBundleVersion": "710",
                                    "CFBundleExecutable": "example-wrapper"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let target = contents.appendingPathComponent("MacOS/example-wrapper")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = thinMachO(sourceVersion: (999, 0, 0))
        try source.write(to: target)
        try Data("#!/bin/bash\nexec \(target.path) \"$@\"\n".utf8).write(to: wrapper)

        let evidence = ExecutableVersionProbe.MetadataVersion(version: "7.1.10", evidence: .executableMetadata)
        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: wrapper), evidence)
        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: target), evidence)
        let unrelated = target.deletingLastPathComponent().appendingPathComponent("unrelated")
        try source.write(to: unrelated)
        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: unrelated), .init(version: "999.0", evidence: .machOSourceVersion))
    }

    func testConfiguredExecutableScanRecordsMachOSourceVersionForDisplayOnly() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("advisory-source-version-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("curl")
        try thinMachO(sourceVersion: (8, 10, 1)).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [root.path], homebrewPrefixes: [], selectedProjectRoots: []
        )
        var artifact = try XCTUnwrap(AdvisoryInventoryScanner(configuration: config).scan().artifacts.first {
            $0.kind == .executable && $0.identifier == "curl"
        })
        XCTAssertEqual(artifact.version, "8.10.1")
        XCTAssertEqual(artifact.versionEvidence, .machOSourceVersion)
        XCTAssertTrue(artifact.hasRecordedVersionEvidence)
        XCTAssertFalse(artifact.hasVersionEvidence)

        let match = AdvisoryCPEMatch(criteria: "cpe:2.3:a:example:curl:*:*:*:*:*:*:*:*",
                                     targets: [AdvisoryTarget(kind: .executable, identifier: "curl")],
                                     versionStartIncluding: "8.0", versionEndExcluding: "9.0")
        XCTAssertFalse(VersionRangeMatcher.matches(artifact, match: match))
        artifact.versionEvidence = .executableVersionProbe
        XCTAssertTrue(artifact.hasVersionEvidence)
        XCTAssertTrue(VersionRangeMatcher.matches(artifact, match: match))
    }

    func testDefaultProbeRejectsSetIDAndShebangExecutablesBeforeRunner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-probe-safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("curl")
        try Data("#!/bin/sh\necho curl 9.9.9\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let artifact = AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: script.path,
                                        version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                                        versionEvidence: nil, source: "Executable path", iconPath: nil)
        let recorder = ProbeRecorder()
        let probe = ExecutableVersionProbe(runner: { _, _, _ in
            recorder.record(url: "unexpected", arguments: [])
            return ExecutableVersionProbe.RawResult(output: Data("curl 9.9.9".utf8), exitCode: 0)
        })

        let result = await probe.probe(artifact)

        XCTAssertEqual(result.status, .unavailable)
        XCTAssertNil(recorder.path)
    }

    private func thinMachO(sourceVersion: (UInt64, UInt64, UInt64), cpu: UInt32 = 0x0100000c) -> Data {
        var data = Data([0xcf, 0xfa, 0xed, 0xfe])
        data.append(contentsOf: littleEndian(cpu))
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        data.append(contentsOf: littleEndian(UInt32(1)))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        data.append(contentsOf: littleEndian(UInt32(0x2a)))
        data.append(contentsOf: littleEndian(UInt32(16)))
        let packed = (sourceVersion.0 << 40) | (sourceVersion.1 << 30) | (sourceVersion.2 << 20)
        data.append(contentsOf: littleEndian(packed))
        return data
    }

    private func fatMachO(sourceVersion: (UInt64, UInt64, UInt64)) -> Data {
        let slice = thinMachO(sourceVersion: sourceVersion)
        let offset = 0x100
        var data = fatTable(is64: false, slices: [(0x0100000c, UInt64(offset), UInt64(slice.count))])
        data.append(Data(count: offset - data.count))
        data.append(slice)
        return data
    }

    private func fatTable(is64: Bool, slices: [(cpu: UInt32, offset: UInt64, size: UInt64)]) -> Data {
        var data = Data([0xca, 0xfe, 0xba, is64 ? 0xbf : 0xbe])
        data.append(contentsOf: bigEndian(UInt32(slices.count)))
        for slice in slices {
            data.append(contentsOf: bigEndian(slice.cpu))
            data.append(contentsOf: bigEndian(UInt32(0)))
            if is64 {
                data.append(contentsOf: withUnsafeBytes(of: slice.offset.bigEndian, Array.init))
                data.append(contentsOf: withUnsafeBytes(of: slice.size.bigEndian, Array.init))
            } else {
                data.append(contentsOf: bigEndian(UInt32(slice.offset)))
                data.append(contentsOf: bigEndian(UInt32(slice.size)))
            }
            data.append(contentsOf: bigEndian(UInt32(2)))
            if is64 { data.append(contentsOf: bigEndian(UInt32(0))) }
        }
        return data
    }

    private func littleEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private func littleEndian(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian, Array.init)
    }
}

private final class ProbeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var path: String?
    private(set) var arguments: [String]?

    func record(url: String, arguments: [String]) {
        lock.lock()
        path = url
        self.arguments = arguments
        lock.unlock()
    }
}
