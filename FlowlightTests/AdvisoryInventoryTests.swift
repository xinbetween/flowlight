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
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .executable })?.version, nil)
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .homebrewFormula })?.versionEvidence, .homebrewInstallReceipt)
        XCTAssertEqual(result.artifacts.first(where: { $0.kind == .nodePackage })?.versionEvidence, .packageJSON)
        XCTAssertEqual(Set(result.artifacts.map(\.kind)).count, 5)
    }

    func testScannerDoesNotTreatCellarDirectoryNameAsVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advisory-inventory-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("Cellar/tool/9.9.9/INSTALL_RECEIPT.json")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"name\":\"tool\"}".utf8).write(to: receipt)

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [root.path], selectedProjectRoots: []
        )
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
        try Data("{\"name\":\"example\",\"version\":\"2.0.0\"}".utf8)
            .write(to: packageDirectory.appendingPathComponent("package.json"))
        try Data("not json".utf8).write(to: malformed)

        let config = AdvisoryInventoryScanner.Configuration(
            applicationRoots: [], executableRoots: [], homebrewPrefixes: [],
            selectedProjectRoots: [AdvisoryInventoryRoot(path: root.path, userSelected: true)]
        )
        let result = AdvisoryInventoryScanner(configuration: config).scan()
        let source = try XCTUnwrap(result.sources.first(where: { $0.source == root.path }))

        XCTAssertEqual(result.artifacts.filter { $0.kind == .nodePackage }.map(\.identifier), ["example"])
        XCTAssertFalse(source.complete)
        XCTAssertFalse(result.complete)
    }

    func testSameNameAcrossKindsHasDistinctStableIDs() throws {
        let artifacts = [
            AdvisoryArtifact(kind: .executable, identifier: "curl", name: "curl", path: "/usr/bin/curl",
                             version: nil, versionScheme: .opaque, identityEvidence: .executablePath,
                             versionEvidence: nil, source: "Executable path", iconPath: nil),
            AdvisoryArtifact(kind: .homebrewFormula, identifier: "curl", name: "curl", path: "/opt/homebrew/Cellar/curl/1",
                             version: "1", versionScheme: .opaque, identityEvidence: .homebrewReceipt,
                             versionEvidence: .homebrewInstallReceipt, source: "Homebrew", iconPath: nil),
            AdvisoryArtifact(kind: .nodePackage, identifier: "curl", name: "curl", path: "/tmp/node_modules/curl",
                             version: "1.0.0", versionScheme: .semver, identityEvidence: .packageManifest,
                             versionEvidence: .packageJSON, source: "package.json", iconPath: nil),
        ]

        XCTAssertEqual(Set(artifacts.map(\.id)).count, 3)
    }
}
