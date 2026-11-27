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

    func testSelectedProjectTraversalSkipsSymlinksAndReportsMalformedManifestAsIncomplete() throws {
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

        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: macho), "6.0.2")
        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: script), "1.125")
    }

    func testExecutableMetadataReadsFatMachOSliceAndRejectsMalformedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-fat-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fat = root.appendingPathComponent("fat-tool")
        let malformed = root.appendingPathComponent("malformed-tool")
        try fatMachO(sourceVersion: (37, 0, 0)).write(to: fat)
        try Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1]).write(to: malformed)

        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: fat), "37.0")
        XCTAssertNil(ExecutableVersionProbe.metadataVersion(at: malformed))
    }

    func testExecutableMetadataReadsLiteralBundleWrapperTargetWithoutExecutingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-wrapper-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Example.app/Contents")
        let wrapper = root.appendingPathComponent("bin/example-wrapper")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "7.1.10", "CFBundleVersion": "710"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let target = contents.appendingPathComponent("MacOS/example-wrapper")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try thinMachO(sourceVersion: (0, 0, 0)).write(to: target)
        try Data("#!/bin/bash\nexec \(target.path) \"$@\"\n".utf8).write(to: wrapper)

        XCTAssertEqual(ExecutableVersionProbe.metadataVersion(at: wrapper), "7.1.10")
    }

    func testConfiguredExecutableScanReadsNativeMachOMetadata() throws {
        let path = "/usr/bin/aa"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path))
        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: ["/usr/bin"], homebrewPrefixes: [], selectedProjectRoots: [],
            homePackageRoot: nil
        )
        let artifact = try XCTUnwrap(AdvisoryInventoryScanner(configuration: config).scan().artifacts.first {
            $0.kind == .executable && $0.identifier == "aa"
        })
        XCTAssertNotNil(artifact.version)
        XCTAssertEqual(artifact.versionEvidence, .executableMetadata)
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

    private func thinMachO(sourceVersion: (UInt64, UInt64, UInt64)) -> Data {
        var data = Data([0xcf, 0xfa, 0xed, 0xfe])
        data.append(contentsOf: Array(repeating: UInt8(0), count: 12))
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
        var data = Data([0xca, 0xfe, 0xba, 0xbe])
        data.append(contentsOf: bigEndian(UInt32(1)))
        data.append(contentsOf: bigEndian(UInt32(0x0100000c)))
        data.append(contentsOf: bigEndian(UInt32(0)))
        data.append(contentsOf: bigEndian(UInt32(offset)))
        data.append(contentsOf: bigEndian(UInt32(slice.count)))
        data.append(contentsOf: bigEndian(UInt32(2)))
        data.append(contentsOf: Array(repeating: UInt8(0), count: offset - data.count))
        data.append(slice)
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
