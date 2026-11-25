import SwiftUI

/// A local-first view of advisories for bundles, executables, Homebrew formulae, and selected project packages.
/// It reports unknown and incomplete states explicitly; a no-match result is never presented as proof of safety.
struct AdvisoriesView: View {
    @ObservedObject var store: AdvisoryStore
    @ObservedObject var updater: AdvisoryCatalogUpdater
    @State private var artifacts: [AdvisoryArtifact] = []
    @State private var sources: [AdvisoryInventorySourceResult] = []
    @State private var scanComplete = false
    @State private var scanning = false
    @State private var probingVersions = false
    @State private var probeProgress = 0
    @State private var probeTotal = 0
    @State private var probeSummary: String?
    @State private var probeStatuses: [String: ExecutableVersionProbe.Status] = [:]
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
            case .unknown: return L("Unknown or unassessed")
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
        .navigationTitle(L("Software advisories"))
        .navigationSubtitle(navigationSubtitle)
        .toolbar { toolbar }
        .task(id: refreshID) { await scan() }
        .task(id: probeRunID) {
            guard let probeRunID else { return }
            await identifyVersions(runID: probeRunID)
        }
        .onDisappear { probeRunID = nil }
        .sheet(item: selectedBinding) { row in
            AdvisoryDetailView(row: row, catalogState: store.catalogState)
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
        ToolbarItemGroup {
            Button { refreshID += 1 } label: {
                Label(L("Rescan software"), systemImage: "arrow.clockwise")
            }
            .disabled(scanning || probingVersions)
            .accessibilityIdentifier("advisories.rescan")
            .help(L("Rescan accessible local software and selected project folders"))

            Button { Task { await updater.checkNow() } } label: {
                Label(L("Refresh catalog"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updater.status == .checking)
            .accessibilityIdentifier("advisories.refresh-catalog")
            .help(L("Check for a newer signed advisory catalog without uploading inventory"))
        }
    }

    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            catalogContext
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
                    Label(L("This inventory may be incomplete. Only bounded, accessible sources are shown; no home-directory crawl is performed."),
                          systemImage: "exclamationmark.triangle")
                    if !sources.filter({ !$0.complete }).isEmpty {
                        Text(L("Limited sources: %@", sources.filter { !$0.complete }.map(\.source).joined(separator: ", ")))
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
        ContentUnavailableView {
            Label(L("No software found"), systemImage: "square.stack.3d.up")
        } description: {
            Text(scanComplete
                 ? L("No accessible software was found in standard locations or selected project folders.")
                 : L("The local software inventory is incomplete or unavailable."))
        } actions: {
            Button(L("Scan again")) { refreshID += 1 }
                .accessibilityIdentifier("advisories.empty.rescan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("advisories.empty")
    }

    private var table: some View {
        Table(filteredRows, selection: $selectedArtifactID, sortOrder: $sortOrder) {
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
            .width(min: 190, ideal: 240)

            TableColumn(L("Identity")) { row in
                Text(row.artifact.identifier)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .help(row.artifact.path)
            }
            .width(min: 150, ideal: 220)

            TableColumn(L("Version")) { row in
                Text(versionText(for: row)).font(.caption).lineLimit(1).help(versionText(for: row))
            }
            .width(min: 130, ideal: 160)

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
            return L("Version unknown")
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
        case .executableVersionProbe: return L("Executable version output")
        case nil: return L("path only")
        }
    }

    private func statusTitle(for row: Row) -> String {
        if !store.catalogReady { return L("Not assessed") }
        if row.isAffected { return L("Affected") }
        if row.isUnknown {
            if let probeStatus = row.probeStatus { return probeStatusTitle(probeStatus) }
            return L("Unknown version")
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
        defer { scanning = false }
        let result = await Task.detached(priority: .utility) {
            AdvisoryInventoryScanner().scan()
        }.value
        guard !Task.isCancelled else { return }
        artifacts = result.artifacts
        sources = result.sources
        scanComplete = result.complete
        probeStatuses = [:]
        probeSummary = nil
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
            probeSummary = L("Identified %lld of %lld executable versions; some remain unknown.", found, candidates.count)
        } else {
            probeSummary = L("Identified %lld of %lld executable versions.", found, candidates.count)
        }
    }
}

private struct AdvisoryDetailView: View {
    let row: AdvisoriesView.Row
    let catalogState: AdvisoryCatalogState?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    FLContextRow(
                        title: L("Software identity"),
                        details: [row.artifact.kind.title, row.artifact.identifier, row.artifact.path,
                                  versionText, L("Evidence: %@", evidenceText)],
                        systemImage: row.artifact.kind.systemImage,
                        identifier: "advisories.detail.identity"
                    )
                    if row.matches.isEmpty {
                        Label(L("No confirmed advisory match is available for this identity and catalog; this is not a safety claim."),
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .padding(Spacing.m)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .flCard()
                            .accessibilityIdentifier("advisories.detail.no-match")
                    } else {
                        ForEach(row.matches) { advisory in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(advisory.cveID).font(.headline.monospaced())
                                    Spacer()
                                    FLPill(text: L("Affected"), systemImage: "exclamationmark.triangle.fill", color: FL.critical)
                                }
                                if let summary = advisory.summary { Text(summary).font(.callout) }
                                if let published = advisory.published {
                                    Text(L("Published %@", published.formatted(date: .abbreviated, time: .omitted)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(Spacing.m)
                            .flCard()
                            .accessibilityIdentifier("advisories.detail.\(advisory.id)")
                        }
                    }
                    if let receipt = catalogState?.receipt {
                        Text(L("Catalog sequence %lld · accepted %@ · matching stayed on this Mac.",
                               receipt.sequence, receipt.acceptedAt.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.l)
            }
            .navigationTitle(row.artifact.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private var versionText: String {
        guard let version = row.artifact.version else { return L("Version unknown") }
        if let build = row.artifact.buildVersion, build != version { return L("Version %@ · build %@", version, build) }
        return version
    }
    private var evidenceText: String {
        switch row.artifact.versionEvidence {
        case .bundleInfoDictionary: return L("Info.plist")
        case .homebrewInstallReceipt: return L("Homebrew install receipt")
        case .packageJSON: return L("package.json")
        case .packageMetadata: return L("Package metadata")
        case .executableVersionProbe: return L("Executable version output")
        case nil: return L("identity/path only")
        }
    }
}

private struct FLContextRow: View {
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
