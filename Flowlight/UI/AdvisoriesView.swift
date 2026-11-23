import SwiftUI

/// A local-first view of application advisories. It deliberately reports unknown and unassessed states instead of
/// turning an incomplete inventory or an empty catalog into a claim that an application is safe.
struct AdvisoriesView: View {
    @ObservedObject var store: AdvisoryStore
    @ObservedObject var updater: AdvisoryCatalogUpdater
    @State private var apps: [InstalledApps.App] = []
    @State private var scanComplete = false
    @State private var scanning = false
    @State private var refreshID = 0
    @State private var selectedBundleID: String?
    @State private var filter: AdvisoryFilter = .all
    @State private var sortOrder = [KeyPathComparator<Row>(\.app.name)]

    enum AdvisoryFilter: String, CaseIterable, Identifiable {
        case all, affected, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All applications")
            case .affected: return L("Affected")
            case .unknown: return L("Unknown or unassessed")
            }
        }
    }

    fileprivate struct Row: Identifiable {
        var app: InstalledApps.App
        var matches: [SecurityAdvisory]
        var id: String { app.id }

        var isUnknown: Bool { app.marketingVersion == nil && app.buildVersion == nil }
        var isAffected: Bool { !matches.isEmpty }
    }

    private var allRows: [Row] {
        apps.map { app in
            Row(app: app, matches: store.matches(AdvisoryAppVersion(
                bundleID: app.bundleID,
                marketingVersion: app.marketingVersion,
                buildVersion: app.buildVersion
            )))
        }
    }

    private var rows: [Row] {
        switch filter {
        case .all: return allRows
        case .affected: return allRows.filter(\.isAffected)
        case .unknown: return allRows.filter { $0.isUnknown || !store.catalogReady }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if scanning && apps.isEmpty {
                    loading
                } else if apps.isEmpty {
                    empty
                } else {
                    content(height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .navigationTitle(L("Application advisories"))
        .navigationSubtitle(navigationSubtitle)
        .toolbar { toolbar }
        .task(id: refreshID) { await scan() }
        .sheet(item: selectedBinding) { row in
            AdvisoryDetailView(row: row, catalogState: store.catalogState)
        }
    }

    private var selectedBinding: Binding<Row?> {
        Binding(
            get: { allRows.first { $0.id == selectedBundleID } },
            set: { selectedBundleID = $0?.id }
        )
    }

    private var navigationSubtitle: String {
        if !store.catalogReady {
            return L("Local matching unavailable · applications are not assessed")
        }
        if let receipt = store.catalogState?.receipt {
            return L("Local matching · catalog sequence %lld", receipt.sequence)
        }
        return L("Local matching · no verified catalog installed")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                refreshID += 1
            } label: {
                Label(L("Rescan applications"), systemImage: "arrow.clockwise")
            }
            .disabled(scanning)
            .accessibilityIdentifier("advisories.rescan")
            .help(L("Rescan accessible application bundles"))

            Button {
                Task { await updater.checkNow() }
            } label: {
                Label(L("Refresh catalog"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(updater.status == .checking)
            .accessibilityIdentifier("advisories.refresh-catalog")
            .help(L("Check for a newer signed advisory catalog"))
        }
    }

    private func content(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            catalogContext
            summary
            HStack(spacing: Spacing.s) {
                Picker(L("Status"), selection: $filter) {
                    ForEach(AdvisoryFilter.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("advisories.filter")
                Spacer(minLength: 0)
                Text(inventorySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("advisories.inventory")
            }

            Divider()

            if !scanComplete {
                Label(L("This inventory may be incomplete; only accessible application bundles are shown."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(FL.warning)
                    .padding(.horizontal, Spacing.s)
                    .accessibilityIdentifier("advisories.incomplete")
            }

            if rows.isEmpty {
                ContentUnavailableView {
                    Label(L("No applications match this filter"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(L("Try another status filter or rescan the application inventory."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("advisories.filtered-empty")
            } else {
                table
                    .frame(height: max(180, height - 250), alignment: .top)
            }
        }
        .padding()
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
            StatTile(title: L("Applications"), value: "\(allRows.count)", systemImage: "square.stack.3d.up")
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
        details.append(L("No application inventory is uploaded"))
        return details
    }

    private var inventorySummary: String {
        let affected = allRows.filter(\.isAffected).count
        return L("%lld applications · %lld affected", allRows.count, affected)
    }

    private var loading: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
            Text(L("Scanning accessible application bundles…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("advisories.loading")
    }

    private var empty: some View {
        ContentUnavailableView {
            Label(L("No applications found"), systemImage: "square.stack.3d.up")
        } description: {
            Text(scanComplete
                 ? L("No accessible application bundles were found in the standard locations.")
                 : L("The application inventory is incomplete or unavailable."))
        } actions: {
            Button(L("Scan again")) { refreshID += 1 }
                .accessibilityIdentifier("advisories.empty.rescan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("advisories.empty")
    }

    private var table: some View {
        Table(rows, selection: $selectedBundleID, sortOrder: $sortOrder) {
            TableColumn(L("Application"), value: \.app.name) { row in
                HStack(spacing: Spacing.s) {
                    AppIconView(path: row.app.path, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.app.name).lineLimit(1)
                        Text(row.app.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .help(row.app.bundleID)
                .accessibilityElement(children: .combine)
                .accessibilityValue(L("%@ · %@", versionText(for: row), statusTitle(for: row)))
                .accessibilityIdentifier("advisories.app.\(row.app.bundleID)")
            }
            .width(min: 190, ideal: 250)

            TableColumn(L("Version")) { row in
                Text(versionText(for: row))
                    .font(.caption)
                    .lineLimit(1)
                    .help(versionText(for: row))
            }
            .width(min: 130, ideal: 155)

            TableColumn(L("Assessment")) { row in
                FLPill(text: statusTitle(for: row), systemImage: statusIcon(for: row), color: statusColor(for: row))
                    .help(statusTitle(for: row))
            }
            .width(min: 125, ideal: 150)

            TableColumn(L("Findings"), value: \.matches.count) { row in
                if row.matches.isEmpty {
                    Text("–").foregroundStyle(.secondary)
                } else {
                    Text("\(row.matches.count)").monospacedDigit().foregroundStyle(FL.critical)
                }
            }
            .width(70)
        }
        .accessibilityIdentifier("advisories.table")
    }

    private func versionText(for row: Row) -> String {
        if let marketing = row.app.marketingVersion {
            if let build = row.app.buildVersion, build != marketing {
                return L("Version %@ · build %@", marketing, build)
            }
            return L("Version %@", marketing)
        }
        if let build = row.app.buildVersion { return L("Build %@ · version unknown", build) }
        return L("Version unknown")
    }

    private func statusTitle(for row: Row) -> String {
        if !store.catalogReady { return L("Not assessed") }
        if !row.matches.isEmpty { return L("Affected") }
        if row.isUnknown { return L("Unknown version") }
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
        let result = await Task.detached(priority: .utility) {
            InstalledApps.scan(refresh: true)
        }.value
        guard !Task.isCancelled else { return }
        apps = result.apps
        scanComplete = result.complete
        scanning = false
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
                        title: L("Application identity"),
                        details: [row.app.bundleID, row.app.path, versionText],
                        systemImage: "app.badge",
                        identifier: "advisories.detail.identity"
                    )
                    if row.matches.isEmpty {
                        Label(L("No confirmed advisory match is available for this application and catalog."),
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
                                    FLPill(text: L("Affected"), systemImage: "exclamationmark.triangle.fill",
                                           color: FL.critical)
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
            .navigationTitle(row.app.name)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 340)
    }

    private var versionText: String {
        row.app.marketingVersion ?? row.app.buildVersion ?? L("Version unknown")
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
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
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
        if let identifier {
            content.accessibilityIdentifier(identifier)
        } else {
            content
        }
    }
}
