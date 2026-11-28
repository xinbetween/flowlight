import AppKit
import SwiftUI

/// A local-first view of advisories for bundles, executables, Homebrew formulae, and selected project packages.
/// It reports unknown and incomplete states explicitly; a no-match result is never presented as proof of safety.
struct AdvisoriesView: View {
    @ObservedObject var store: AdvisoryStore
    @ObservedObject var updater: AdvisoryCatalogUpdater
    @EnvironmentObject private var nav: AppNavigation
    @State private var artifacts: [AdvisoryArtifact] = []
    @State private var sources: [AdvisoryInventorySourceResult] = []
    @State private var scanComplete = false
    @State private var scanning = false
    @State private var probingVersions = false
    @State private var probeProgress = 0
    @State private var probeTotal = 0
    @State private var probeSummary: String?
    @State private var probeStatuses: [String: ExecutableVersionProbe.Status] = [:]
    @State private var selectedProjectFolderCount = 0
    @State private var homeScanEnabled = AdvisoryInventoryPreferences.homeScanEnabled
    @State private var refreshID = 0
    @State private var probeRunID: UUID?
    @State private var selectedArtifactID: String?
    @State private var statusFilter: StatusFilter = .all
    @State private var kindFilter: KindFilter = .all
    @State private var sortOrder = [KeyPathComparator<Row>(\.artifact.name)]

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, affected, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All")
            case .affected: return L("Affected")
            case .unknown: return L("Needs review")
            }
        }
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all, application, executable, packages
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All software")
            case .application: return AdvisoryArtifactKind.application.title
            case .executable: return AdvisoryArtifactKind.executable.title
            case .packages: return L("Packages")
            }
        }
        func matches(_ artifact: AdvisoryArtifact) -> Bool {
            switch self {
            case .all: return true
            case .application: return artifact.kind == .application
            case .executable: return artifact.kind == .executable
            case .packages: return artifact.kind.isPackage
            }
        }
    }

    fileprivate struct Row: Identifiable {
        var artifact: AdvisoryArtifact
        var matches: [SecurityAdvisory]
        var probeStatus: ExecutableVersionProbe.Status?
        var id: String { artifact.id }
        var isUnknown: Bool { !artifact.hasVersionEvidence }
        var isAffected: Bool { !matches.isEmpty }
    }

    private var allRows: [Row] {
        artifacts.map { artifact in
            Row(artifact: artifact, matches: store.matches(artifact), probeStatus: probeStatuses[artifact.id])
        }
    }

    private var filteredRows: [Row] {
        allRows.filter { row in
            let kindMatches = kindFilter.matches(row.artifact)
            let statusMatches: Bool
            switch statusFilter {
            case .all: statusMatches = true
            case .affected: statusMatches = row.isAffected
            case .unknown: statusMatches = row.isUnknown || !store.catalogReady
            }
            return kindMatches && statusMatches
        }
    }

    var body: some View {
        Group {
            switch nav.advisoriesTab {
            case .agent:
                AgentAdvisoriesView()
            case .software:
                softwareContent
            }
        }
        .navigationTitle(nav.advisoriesTab == .agent ? L("Agent advisories") : L("Software advisories"))
        .navigationSubtitle(nav.advisoriesTab == .agent
                            ? L("Local agent metadata · bounded, no execution")
                            : navigationSubtitle)
        .toolbar { toolbar }
    }

    private var softwareContent: some View {
        GeometryReader { geometry in
            Group {
                if scanning && artifacts.isEmpty {
                    loading
                } else if artifacts.isEmpty {
                    empty
                } else {
                    content(height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task(id: refreshID) { await scan() }
        .task(id: probeRunID) {
            guard let probeRunID else { return }
            await identifyVersions(runID: probeRunID)
        }
        .onDisappear { probeRunID = nil }
        .sheet(item: selectedBinding) { row in
            AdvisoryDetailView(row: row, catalogState: store.catalogState, catalogReady: store.catalogReady,
                               status: statusTitle(for: row), version: row.artifact.version ?? versionText(for: row))
        }
    }

    private var selectedBinding: Binding<Row?> {
        Binding(
            get: { allRows.first { $0.id == selectedArtifactID } },
            set: { selectedArtifactID = $0?.id }
        )
    }

    private var navigationSubtitle: String {
        if !store.catalogReady { return L("Local matching unavailable · software is not assessed") }
        if let receipt = store.catalogState?.receipt {
            return L("Local matching · catalog sequence %lld", receipt.sequence)
        }
        return L("Local matching · no verified catalog installed")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker(L("Advisories"), selection: $nav.advisoriesTab) {
                ForEach(AdvisoriesTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("advisories.tabs")
        }
        if nav.advisoriesTab == .software {
            ToolbarItemGroup {
                Button { refreshID += 1 } label: {
                    Label(L("Rescan software"), systemImage: "arrow.clockwise")
                }
                .disabled(scanning || probingVersions)
                .accessibilityIdentifier("advisories.rescan")
                .help(L("Rescan accessible local software and selected project folders"))

                Button { addProjectFolder() } label: {
                    Label(L("Add project folder…"), systemImage: "folder.badge.plus")
                }
                .disabled(scanning || probingVersions)
                .accessibilityIdentifier("advisories.add-project-folder")
                .help(L("Choose a project folder to inspect bounded package metadata"))

                Button { Task { await updater.checkNow() } } label: {
                    Label(L("Refresh catalog"), systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updater.status == .checking)
                .accessibilityIdentifier("advisories.refresh-catalog")
                .help(L("Check for a newer signed advisory catalog without uploading inventory"))
            }
        }
    }

    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            catalogContext
            homeScanScope
            inventorySources
            if artifacts.allSatisfy({ !$0.kind.isPackage }) {
                projectFolderGuidance
            }
            versionProbeCard
            summary
            HStack(spacing: Spacing.s) {
                Picker(L("Status"), selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { value in Text(value.title).tag(value) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("advisories.filter")
                Picker(L("Kind"), selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { value in Text(value.title).tag(value) }
                }
                .frame(width: 180)
                .accessibilityIdentifier("advisories.kind-filter")
                Spacer(minLength: 0)
                Text(inventorySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("advisories.inventory")
            }

            Divider()

            if !scanComplete || sources.contains(where: { !$0.complete }) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L("This inventory may be incomplete. Only bounded, accessible sources are shown."),
                          systemImage: "exclamationmark.triangle")
                    ForEach(sources.filter { !$0.complete }, id: \.source) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("Limited source: %@", source.source))
                            if let detail = source.detail { Text(detail) }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .foregroundStyle(FL.warning)
                .padding(.horizontal, Spacing.s)
                .accessibilityIdentifier("advisories.incomplete")
            }

            if filteredRows.isEmpty {
                ContentUnavailableView {
                    Label(L("No software matches this filter"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(L("Try another status or software-kind filter, or rescan the local inventory."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("advisories.filtered-empty")
            } else {
                table.frame(height: max(180, height - 250), alignment: .top)
            }
        }
        .padding()
    }

    private var versionProbeCard: some View {
        let eligible = artifacts.filter { ExecutableVersionProbe.isEligible($0) }.count
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "terminal").foregroundStyle(FL.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Identify executable versions")).font(.callout.weight(.medium))
                    Text(L("Runs bounded local version checks for supported executables; inventory never leaves this Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.s)
                if probingVersions {
                    Button(L("Stop")) { probeRunID = nil }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("advisories.version-probe.stop")
                } else {
                    Button(L("Scan now")) { probeRunID = UUID() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scanning || eligible == 0)
                        .accessibilityIdentifier("advisories.version-probe.start")
                }
            }
            if probingVersions {
                ProgressView(value: Double(probeProgress), total: Double(max(probeTotal, 1)))
                    .accessibilityIdentifier("advisories.version-probe.progress")
                Text(L("Checked %lld of %lld supported executables", probeProgress, probeTotal))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let probeSummary {
                Text(probeSummary)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("advisories.version-probe.summary")
            } else {
                Text(L("%lld supported executable%@ found. Version checks are explicit and time-limited.", eligible, eligible == 1 ? "" : "s"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
        .flCard(radius: Radius.chip)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.version-probe")
    }

    private var inventorySources: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L("Inventory sources"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sources, id: \.source) { source in
                HStack(spacing: Spacing.s) {
                    Image(systemName: source.complete ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(source.complete ? FL.good : FL.warning)
                    Text(source.source)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text(L("%lld found", source.discovered))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(source.complete ? L("Complete") : L("Limited"))
                        .font(.caption)
                        .foregroundStyle(source.complete ? FL.good : FL.warning)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("advisories.source.\(source.source)")
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .flCard(radius: Radius.chip)
        .accessibilityIdentifier("advisories.sources")
    }

    private var homeScanScope: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Label(L("Home folder scan"), systemImage: "house.fill")
                    .font(.callout.weight(.medium))
                Spacer(minLength: Spacing.s)
                Toggle(L("Scan home folder recursively"), isOn: $homeScanEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(homeScanEnabled ? L("Pause home folder scanning") : L("Scan home folder recursively"))
                    .accessibilityIdentifier("advisories.home-scan.toggle")
                    .onChange(of: homeScanEnabled) { _, enabled in
                        AdvisoryInventoryPreferences.setHomeScanEnabled(enabled)
                        refreshID += 1
                    }
            }
            Text(homeScanEnabled
                 ? L("Flowlight reads package metadata locally with bounded depth and directory limits. It skips system, generated, hidden, and cache folders and never executes project code.")
                 : L("Home folder scan is paused. Re-enable it to inspect package metadata under your home folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let source = sources.first(where: { $0.source == L("Home folder") }), let detail = source.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(source.complete ? .secondary : FL.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.home-scan.scope")
    }

    private var projectFolderGuidance: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(L("Inspect project packages"), systemImage: "shippingbox.fill")
                .font(.callout.weight(.medium))
            Text(L("Node packages and lockfiles are read locally under your home folder and any project folders you choose. Flowlight skips system, generated, and cache folders and never executes project code."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if selectedProjectFolderCount == 0 {
                Text(L("No project folder selected yet."))
                    .font(.caption)
                    .foregroundStyle(FL.warning)
            } else {
                Text(L("Selected project folders: %lld", selectedProjectFolderCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: Spacing.s) {
                Button(L("Add project folder…")) { addProjectFolder() }
                    .buttonStyle(.borderedProminent)
                    .disabled(scanning || probingVersions)
                    .accessibilityIdentifier("advisories.add-project-folder.guidance")
                Button(L("Rescan software")) { refreshID += 1 }
                    .buttonStyle(.bordered)
                    .disabled(scanning || probingVersions)
                    .accessibilityIdentifier("advisories.guidance.rescan")
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
        .accessibilityIdentifier("advisories.project-folder-guidance")
    }

    private var catalogContext: some View {
        FLContextRow(
            title: catalogTitle,
            details: catalogDetails,
            systemImage: store.catalogReady ? "checkmark.shield" : "questionmark.shield",
            tint: store.catalogReady ? FL.good : FL.warning,
            identifier: "advisories.catalog"
        )
    }

    private var summary: some View {
        let affected = allRows.filter(\.isAffected).count
        let needsReview = allRows.filter { $0.isUnknown || !store.catalogReady }.count
        let catalogValue: String = {
            if !store.catalogReady { return L("Review") }
            if let sequence = store.catalogState?.receipt?.sequence { return "#\(sequence)" }
            return L("Ready")
        }()
        return HStack(spacing: Spacing.s) {
            StatTile(title: L("Software"), value: "\(allRows.count)", systemImage: "square.stack.3d.up")
            StatTile(title: L("Affected"), value: "\(affected)", systemImage: "exclamationmark.triangle",
                     tint: affected > 0 ? FL.critical : .secondary)
            StatTile(title: L("Needs review"), value: "\(needsReview)", systemImage: "questionmark.circle",
                     tint: needsReview > 0 ? FL.warning : .secondary)
            StatTile(title: L("Catalog"), value: catalogValue, systemImage: "checkmark.shield",
                     tint: store.catalogReady ? FL.good : FL.warning)
        }
        .accessibilityElement(children: .contain)
    }

    private var catalogTitle: String {
        if store.catalogReady { return L("Verified advisory catalog") }
        if store.isRecovering { return L("Advisory catalog needs recovery") }
        return L("Advisory matching unavailable")
    }

    private var catalogDetails: [String] {
        var details: [String] = [L("Local matching only")]
        if let receipt = store.catalogState?.receipt {
            details.append(L("Sequence %lld", receipt.sequence))
            details.append(L("Checked %@", receipt.acceptedAt.formatted(date: .abbreviated, time: .shortened)))
        } else {
            details.append(L("No verified catalog installed"))
        }
        details.append(L("Software inventory never leaves this Mac"))
        return details
    }

    private var inventorySummary: String {
        let affected = allRows.filter(\.isAffected).count
        return L("%lld software artifacts · %lld affected", allRows.count, affected)
    }

    private var loading: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
            Text(L("Scanning bounded local software sources…")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("advisories.loading")
    }

    private var empty: some View {
        VStack(spacing: Spacing.m) {
            homeScanScope
            ContentUnavailableView {
                Label(L("No software found"), systemImage: "square.stack.3d.up")
            } description: {
                Text(scanComplete
                     ? (selectedProjectFolderCount == 0
                        ? L("No accessible software was found. Home folder scanning is bounded and can be paused above; choose a project folder for an additional focused scan, or scan again.")
                        : L("No accessible software was found in standard locations, the home folder, or selected project folders."))
                     : L("The local software inventory is incomplete or unavailable."))
            } actions: {
                VStack(spacing: Spacing.s) {
                    Button(L("Scan again")) { refreshID += 1 }
                        .accessibilityIdentifier("advisories.empty.rescan")
                    Button(L("Add project folder…")) { addProjectFolder() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("advisories.empty.add-project-folder")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .accessibilityIdentifier("advisories.empty")
    }

    private var table: some View {
        Table(filteredRows.sorted(using: sortOrder), selection: $selectedArtifactID, sortOrder: $sortOrder) {
            TableColumn(L("Software"), value: \.artifact.name) { row in
                HStack(spacing: Spacing.s) {
                    if row.artifact.kind == .application, let iconPath = row.artifact.iconPath {
                        AppIconView(path: iconPath, size: 22)
                    } else {
                        Image(systemName: row.artifact.kind.systemImage)
                            .foregroundStyle(FL.accent)
                            .frame(width: 22)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.artifact.name).lineLimit(1)
                        Text(row.artifact.packageManager?.title ?? row.artifact.kind.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(row.artifact.identifier)
                .accessibilityElement(children: .combine)
                .accessibilityValue(L("%@ · %@", versionText(for: row), statusTitle(for: row)))
                .accessibilityIdentifier(row.artifact.kind == .application
                                         ? "advisories.app.\(row.artifact.identifier)"
                                         : "advisories.artifact.\(row.artifact.id)")
            }
            .width(min: 150, ideal: 240)

            TableColumn(L("Identity")) { row in
                Text(row.artifact.identifier)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .help(row.artifact.identifier)
            }
            .width(min: 100, ideal: 160)

            TableColumn(L("Path"), value: \.artifact.path) { row in
                Text(verbatim: row.artifact.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.artifact.path)
                    .accessibilityIdentifier("advisories.artifact.path")
            }
            .width(min: 130, ideal: 280)

            TableColumn(L("Version")) { row in
                Text(versionText(for: row)).font(.caption).lineLimit(1).help(versionText(for: row))
            }
            .width(min: 110, ideal: 160)

            TableColumn(L("Assessment")) { row in
                FLPill(text: statusTitle(for: row), systemImage: statusIcon(for: row), color: statusColor(for: row))
                    .help(statusTitle(for: row))
            }
            .width(min: 125, ideal: 150)

            TableColumn(L("Findings"), value: \.matches.count) { row in
                if row.matches.isEmpty { Text("–").foregroundStyle(.secondary) }
                else { Text("\(row.matches.count)").monospacedDigit().foregroundStyle(FL.critical) }
            }
            .width(70)
        }
        .accessibilityIdentifier("advisories.table")
    }

    private func versionText(for row: Row) -> String {
        guard let version = row.artifact.version else {
            if let probeStatus = row.probeStatus {
                return probeStatusTitle(probeStatus)
            }
            if row.artifact.kind == .executable {
                return ExecutableVersionProbe.isEligible(row.artifact)
                    ? L("Version check available")
                    : L("No authoritative version")
            }
            return L("No version evidence")
        }
        if let build = row.artifact.buildVersion, build != version {
            return L("Version %@ · build %@ · %@", version, build, versionEvidenceTitle(for: row.artifact))
        }
        return L("Version %@ · %@", version, versionEvidenceTitle(for: row.artifact))
    }

    private func probeStatusTitle(_ status: ExecutableVersionProbe.Status) -> String {
        switch status {
        case .found: return L("Version identified")
        case .notAttempted: return L("Version check not attempted")
        case .unavailable: return L("Executable unavailable")
        case .nonZeroExit: return L("Version command failed")
        case .timedOut: return L("Version check timed out")
        case .outputLimitExceeded: return L("Version output exceeded the limit")
        case .cancelled: return L("Version check cancelled")
        case .invalidOutput: return L("Version output not recognized")
        }
    }

    private func versionEvidenceTitle(for artifact: AdvisoryArtifact) -> String {
        switch artifact.versionEvidence {
        case .bundleInfoDictionary: return L("Info.plist")
        case .homebrewInstallReceipt: return L("Homebrew receipt")
        case .packageJSON: return L("package.json")
        case .packageMetadata: return L("Package metadata")
        case .executableMetadata: return L("Executable metadata")
        case .machOSourceVersion: return L("Mach-O source version (display only)")
        case .executableVersionProbe: return L("Executable version output")
        case nil: return L("path only")
        }
    }

    private func statusTitle(for row: Row) -> String {
        if !store.catalogReady { return L("Not assessed") }
        if row.isAffected { return L("Affected") }
        if row.isUnknown {
            if let probeStatus = row.probeStatus { return probeStatusTitle(probeStatus) }
            if row.artifact.kind == .executable {
                return ExecutableVersionProbe.isEligible(row.artifact)
                    ? L("Version check available")
                    : L("No authoritative version")
            }
            if row.artifact.hasRecordedVersionEvidence {
                return L("Version recorded; comparison unavailable")
            }
            return L("Not assessed for version")
        }
        return L("No matching advisory")
    }

    private func statusIcon(for row: Row) -> String {
        if !store.catalogReady || row.isUnknown { return "questionmark.circle" }
        return row.isAffected ? "exclamationmark.triangle.fill" : "checkmark.circle"
    }

    private func statusColor(for row: Row) -> Color {
        if !store.catalogReady || row.isUnknown { return FL.warning }
        return row.isAffected ? FL.critical : FL.good
    }

    private func scan() async {
        scanning = true
        probeRunID = nil
        selectedProjectFolderCount = AdvisoryInventoryPreferences.selectedProjectRoots.count
        let result = await Task.detached(priority: .utility) {
            AdvisoryInventoryScanner().scan()
        }.value
        guard !Task.isCancelled else {
            scanning = false
            return
        }
        artifacts = result.artifacts
        sources = result.sources
        scanComplete = result.complete
        probeStatuses = [:]
        probeSummary = nil
        scanning = false
    }

    @MainActor
    private func addProjectFolder() {
        guard let root = AdvisoryProjectFolderPicker.choose() else { return }
        var roots = AdvisoryInventoryPreferences.selectedProjectRoots
        guard !roots.contains(where: { $0.id == root.id }) else {
            selectedProjectFolderCount = roots.count
            return
        }
        roots.append(root)
        roots.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        AdvisoryInventoryPreferences.saveSelectedProjectRoots(roots)
        selectedProjectFolderCount = roots.count
        refreshID += 1
    }

    private func identifyVersions(runID: UUID) async {
        guard !scanning else { return }
        let candidates = artifacts.filter { ExecutableVersionProbe.isEligible($0) }
        let probe = ExecutableVersionProbe()
        probeProgress = 0
        probeTotal = min(candidates.count, probe.maximumProbes)
        probingVersions = true
        defer {
            probingVersions = false
            if probeRunID == runID { probeRunID = nil }
        }
        guard !candidates.isEmpty else {
            probeSummary = L("No supported executable versions were found to identify.")
            return
        }

        var found = 0
        var attempted = 0
        for candidate in candidates.prefix(probe.maximumProbes) {
            guard !Task.isCancelled else { break }
            let result = await probe.probe(candidate)
            probeStatuses[candidate.id] = result.status
            attempted += 1
            if result.status == .found, let version = result.version,
               let index = artifacts.firstIndex(where: { $0.id == candidate.id }) {
                artifacts[index].version = version
                artifacts[index].versionEvidence = .executableVersionProbe
                artifacts[index].versionScheme = .opaque
                found += 1
            }
            probeProgress = attempted
        }
        if Task.isCancelled || attempted < candidates.count {
            probeSummary = L("Identified %lld of %lld executable versions; some remain unavailable.", found, candidates.count)
        } else {
            probeSummary = L("Identified %lld of %lld executable versions.", found, candidates.count)
        }
    }
}

private struct AdvisoryDetailView: View {
    let row: AdvisoriesView.Row
    let catalogState: AdvisoryCatalogState?
    let catalogReady: Bool
    let status: String
    let version: String
    @Environment(\.dismiss) private var dismiss

    private var artifact: AdvisoryArtifact { row.artifact }
    private var hasMatches: Bool { catalogReady && row.isAffected }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    header
                    identity
                    assessment
                    catalogEvidence
                }
                .padding(Spacing.l)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
        .frame(width: 620, height: hasMatches ? 580 : 490)
        .accessibilityIdentifier("advisories.detail")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            if artifact.kind == .application, let iconPath = artifact.iconPath {
                AppIconView(path: iconPath, size: 44)
            } else {
                Image(systemName: artifact.kind.systemImage)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(FL.accent)
                    .frame(width: 44, height: 44)
                    .background(FL.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(verbatim: artifact.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(artifact.packageManager?.title ?? artifact.kind.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            // Keep a benign-looking checkmark out of the no-match and unavailable states.
            FLPill(text: status, systemImage: hasMatches ? "exclamationmark.triangle.fill" : "info.circle",
                   color: hasMatches ? FL.critical : (catalogReady && !row.isUnknown ? .secondary : FL.warning))
        }
        .accessibilityIdentifier("advisories.detail.header")
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(L("Software identity"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
                metadata(L("Identity"), artifact.identifier, monospaced: true)
                metadata(L("Version"), version, monospaced: artifact.version != nil)
                if let build = artifact.buildVersion { metadata(L("Build"), build, monospaced: true) }
                metadata(L("Source"), artifact.source)
                metadata(L("Version evidence"), evidenceText)
            }
            Divider()
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Label(L("Path"), systemImage: "folder")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(artifact.path, forType: .string)
                    } label: {
                        Label(L("Copy Path"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("advisories.detail.copy-path")
                }
                Text(verbatim: artifact.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("advisories.detail.path")
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.detail.identity")
    }

    private var assessment: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L("Assessment")).font(.headline).accessibilityAddTraits(.isHeader)
            if hasMatches {
                ForEach(row.matches) { advisory in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(verbatim: advisory.cveID)
                            .font(.headline.monospaced())
                            .textSelection(.enabled)
                        if let summary = advisory.summary {
                            Text(verbatim: summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                        if advisory.published != nil || advisory.lastModified != nil {
                            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
                                if let published = advisory.published {
                                    metadata(L("Published"), published.formatted(date: .abbreviated, time: .omitted))
                                }
                                if let modified = advisory.lastModified {
                                    metadata(L("Last modified"), modified.formatted(date: .abbreviated, time: .omitted))
                                }
                            }
                        }
                    }
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flCard()
                    .accessibilityIdentifier("advisories.detail.\(advisory.id)")
                }
            } else {
                Text(assessmentExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(catalogReady && !row.isUnknown ? "advisories.detail.no-match" : "advisories.detail.not-assessed")
            }
        }
    }

    private var assessmentExplanation: String {
        if !catalogReady { return L("No verified catalog installed") }
        if row.isUnknown {
            return artifact.hasRecordedVersionEvidence
                ? L("Version recorded; comparison unavailable")
                : L("No authoritative version")
        }
        return L("No confirmed advisory match is available for this identity and catalog; this is not a safety claim.")
    }

    private var catalogEvidence: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Divider()
            Label(L("Catalog evidence"), systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let receipt = catalogState?.receipt {
                Text(L("Catalog sequence %lld · accepted %@ · matching stayed on this Mac.",
                       receipt.sequence, receipt.acceptedAt.formatted(date: .abbreviated, time: .shortened)))
            } else {
                Text(L("Software inventory never leaves this Mac"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("advisories.detail.catalog")
    }

    private func metadata(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(verbatim: value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .gridColumnAlignment(.leading)
        }
        .font(.callout)
    }

    private var evidenceText: String {
        switch row.artifact.versionEvidence {
        case .bundleInfoDictionary: return L("Info.plist")
        case .homebrewInstallReceipt: return L("Homebrew install receipt")
        case .packageJSON: return L("package.json")
        case .packageMetadata: return L("Package metadata")
        case .executableMetadata: return L("Executable metadata")
        case .machOSourceVersion: return L("Mach-O source version (display only)")
        case .executableVersionProbe: return L("Executable version output")
        case nil: return L("identity/path only")
        }
    }
}

struct FLContextRow: View {
    var title: String
    var details: [String] = []
    var systemImage: String = "scope"
    var tint: Color = FL.accent
    var identifier: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: systemImage).foregroundStyle(tint).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(details.joined(separator: " · "))
        .modifier(AdvisoryAccessibilityIdentifier(identifier: identifier))
    }
}

private struct AdvisoryAccessibilityIdentifier: ViewModifier {
    let identifier: String?
    func body(content: Content) -> some View {
        if let identifier { content.accessibilityIdentifier(identifier) } else { content }
    }
}
