import SwiftUI

@MainActor
final class AgentAdvisoryModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case complete(AgentAdvisoryScanResult)
        case cancelled
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: AgentAdvisoryScanResult?
    @Published private(set) var additionalRoots: [AdvisoryInventoryRoot]
    @Published private(set) var analysis: AgentAdvisoryAnalysisState = .idle
    private let analyzer: any AgentAdvisoryAnalyzing
    private var analysisMode = AgentAdvisoryAnalysisMode.defaultMode
    private var analysisTask: Task<Void, Never>?
    private var analysisID = UUID()
    private var worker: Task<AgentAdvisoryScanResult, Never>?
    private var runID = UUID()

    init(analyzer: any AgentAdvisoryAnalyzing = AppleAgentAdvisoryAnalyzer(),
         additionalRoots: [AdvisoryInventoryRoot] = AgentAdvisoryRootPreferences.selectedRoots) {
        self.analyzer = analyzer
        self.additionalRoots = additionalRoots
    }

    func selectAnalysisMode(_ mode: AgentAdvisoryAnalysisMode) {
        guard mode != analysisMode else { return }
        analysisMode = mode
        startAnalysis(result)
    }

    @discardableResult
    func startAnalysis(_ result: AgentAdvisoryScanResult?) -> Task<Void, Never>? {
        stopAnalysis()
        guard analysisMode == .appleOnDevice, let result else { return nil }
        let input = AgentAdvisoryAnalysisInput(result: result)
        guard !input.evidence.isEmpty else {
            analysis = .noEvidence
            return nil
        }
        let id = analysisID
        analysis = .analyzing
        let task = Task { [weak self, analyzer] in
            let response = await analyzer.analyze(input)
            guard let self, !Task.isCancelled, self.analysisID == id else { return }
            self.analysis = response
            self.analysisTask = nil
        }
        analysisTask = task
        return task
    }

    private func stopAnalysis() {
        analysisID = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        analysis = .idle
    }

    var isScanning: Bool { if case .scanning = phase { return true }; return false }

    var homeRoot: URL { FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }

    func displayPath(_ path: String) -> String {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = homeRoot.path
        if canonical == home { return "~" }
        if canonical.hasPrefix(home + "/") {
            return "~/" + canonical.dropFirst(home.count + 1)
        }
        let components = canonical.split(separator: "/", omittingEmptySubsequences: true)
        if let index = components.firstIndex(of: "Users"), components.count > index + 1 {
            var redacted = components.map(String.init)
            redacted[index + 1] = "<user>"
            return "/" + redacted.joined(separator: "/")
        }
        return canonical
    }

    func addRoot(_ root: AdvisoryInventoryRoot) {
        guard !isScanning else { return }
        let canonical = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().standardizedFileURL
        guard canonical.path != "/", canonical.path != homeRoot.path else { return }
        guard !additionalRoots.contains(where: {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical.path
        }) else { return }
        additionalRoots.append(AdvisoryInventoryRoot(path: canonical.path, userSelected: true,
                                                       bookmarkData: root.bookmarkData))
        additionalRoots.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        AgentAdvisoryRootPreferences.save(additionalRoots)
        clear()
    }

    func removeRoot(_ root: AdvisoryInventoryRoot) {
        guard !isScanning else { return }
        additionalRoots.removeAll { $0.id == root.id }
        AgentAdvisoryRootPreferences.save(additionalRoots)
        clear()
    }

    func startConfiguredScan() {
        cancel()
        let token = UUID()
        runID = token
        phase = .scanning
        result = nil
        let access = beginSecurityScopedAccess()
        let configuration = AgentAdvisoryScanConfiguration(roots: [homeRoot] + access.readable,
                                                            unavailableRoots: access.unavailable)
        let worker = Task.detached(priority: .utility) {
            defer { access.scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            return AgentAdvisoryScanner(configuration: configuration).scan()
        }
        self.worker = worker
        Task { @MainActor [weak self] in
            let value = await worker.value
            guard let self, self.runID == token, !Task.isCancelled else { return }
            self.result = value
            self.phase = .complete(value)
            self.worker = nil
            self.startAnalysis(value)
        }
    }

    func cancel() {
        runID = UUID()
        worker?.cancel()
        worker = nil
        stopAnalysis()
        if isScanning { phase = .cancelled }
    }

    func clear() {
        cancel()
        result = nil
        phase = .idle
    }

    private func beginSecurityScopedAccess() -> (readable: [URL], scoped: [URL], unavailable: [URL]) {
        var readable: [URL] = []
        var scoped: [URL] = []
        var unavailable: [URL] = []
        var refreshedRoots = additionalRoots
        for (index, root) in additionalRoots.enumerated() {
            let original = URL(fileURLWithPath: root.path)
            guard let bookmark = root.bookmarkData else {
                readable.append(original)
                continue
            }
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                  resolved.isFileURL, resolved.standardizedFileURL.path != "/",
                  resolved.startAccessingSecurityScopedResource() else {
                unavailable.append(original)
                continue
            }
            readable.append(resolved)
            scoped.append(resolved)
            if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope],
                                                                includingResourceValuesForKeys: nil, relativeTo: nil) {
                refreshedRoots[index] = .init(path: resolved.path, userSelected: true, bookmarkData: refreshed)
            }
        }
        if refreshedRoots != additionalRoots {
            additionalRoots = refreshedRoots
            AgentAdvisoryRootPreferences.save(refreshedRoots)
        }
        return (readable, scoped, unavailable)
    }
}

struct AgentAdvisoriesView: View {
    @Binding var showsSettings: Bool
    @State private var showsCoverage = false
    @StateObject private var model = AgentAdvisoryModel()
    @AppStorage("FLAgentAdvisoryHomeScanConsent") private var homeScanConsent = false
    @AppStorage(AgentAdvisoryAnalysisMode.preferenceKey) private var analysisMode = AgentAdvisoryAnalysisMode.defaultMode
    @State private var requestHomeConsent = false
    @State private var automaticScanRequested = false
    @State private var selectedFindingID: String?
    @State private var severityFilter: SeverityFilter = .all
    @State private var categoryFilter: CategoryFilter = .all

    private enum SeverityFilter: String, CaseIterable, Identifiable {
        case all, high, review
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All")
            case .high: return L("High and critical")
            case .review: return L("Needs review")
            }
        }
        func matches(_ finding: AgentAdvisoryFinding) -> Bool {
            switch self {
            case .all: return true
            case .high: return finding.severity >= .high
            case .review: return finding.severity >= .medium
            }
        }
    }

    private enum CategoryFilter: String, CaseIterable, Identifiable {
        case all, instructions, hooks, permissions, mcp, plugins, gateway, credentials
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("All surfaces")
            case .instructions: return L("Instructions")
            case .hooks: return L("Hooks")
            case .permissions: return L("Permissions")
            case .mcp: return L("MCP")
            case .plugins: return L("Plugins")
            case .gateway: return L("Gateway")
            case .credentials: return L("Credentials")
            }
        }
        func matches(_ finding: AgentAdvisoryFinding) -> Bool {
            self == .all || finding.category.rawValue == rawValue
        }
    }

    private var scanResult: AgentAdvisoryScanResult? { model.result }
    private var findings: [AgentAdvisoryFinding] {
        guard let scanResult else { return [] }
        return scanResult.findings.filter { severityFilter.matches($0) && categoryFilter.matches($0) }
    }
    private var selectedBinding: Binding<AgentAdvisoryFinding?> {
        Binding(
            get: { findings.first { $0.id == selectedFindingID } },
            set: { selectedFindingID = $0?.id }
        )
    }

    var body: some View {
        GeometryReader { window in
            VStack(alignment: .leading, spacing: Spacing.m) {
                switch model.phase {
                case .idle:
                    idleCard
                case .scanning:
                    scanningCard
                case .cancelled:
                    cancelledCard
                case .complete(let result):
                    overview(result)
                        .fixedSize(horizontal: false, vertical: true)
                    resultContent(result)
                }
            }
            .padding(Spacing.l)
            .frame(width: window.size.width, height: window.size.height, alignment: .topLeading)
        }
        .task {
            model.selectAnalysisMode(analysisMode)
            if homeScanConsent {
                if model.phase == .idle || model.phase == .cancelled {
                    model.startConfiguredScan()
                } else if let result = model.result, model.analysis == .idle {
                    model.startAnalysis(result)
                }
            } else if !automaticScanRequested {
                automaticScanRequested = true
                requestHomeConsent = true
            }
        }
        .onDisappear { model.cancel() }
        .onChange(of: analysisMode) { _, mode in model.selectAnalysisMode(mode) }
        .alert(L("Allow home folder scans?"), isPresented: $requestHomeConsent) {
            Button(L("Allow scans")) {
                homeScanConsent = true
                model.startConfiguredScan()
            }
            Button(L("Not now"), role: .cancel) {}
        } message: {
            Text(L("Flowlight will inspect bounded Agent metadata under ~ locally. It will not execute files, upload findings, or enter protected media folders. macOS privacy controls may still make coverage incomplete."))
        }
        .onChange(of: model.phase) { _, phase in
            if case .complete = phase { return }
            selectedFindingID = nil
        }
        .sheet(isPresented: $showsSettings) { agentSettings }
        .sheet(item: selectedBinding) { finding in
            AgentAdvisoryFindingDetail(finding: finding, category: categoryTitle(finding.category))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.agent")
    }

    private var agentSettings: some View {
        AdvisorySettingsSheet(title: AdvisoriesTab.agent.settingsTitle, identifier: "advisories.agent.settings") {
            Form {
                Section {
                    scanScope
                } header: {
                    Text(L("Agent scan folders"))
                }
                Section {
                    Picker(L("Advisory analysis"), selection: $analysisMode) {
                        ForEach(AgentAdvisoryAnalysisMode.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("advisories.agent.model")
                }
                if scanResult != nil {
                    Section {
                        Button(L("Clear findings"), role: .destructive) { model.clear() }
                            .accessibilityIdentifier("advisories.agent.clear")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private var scanScope: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(L("With your consent, Flowlight scans your home folder and any folders you add."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.s) {
                Image(systemName: "house")
                    .foregroundStyle(FL.accent)
                Text(L("Home folder (default)"))
                Text("(~)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            ForEach(model.additionalRoots) { root in
                HStack(spacing: Spacing.s) {
                    Image(systemName: "folder")
                        .foregroundStyle(FL.accent)
                    Text(verbatim: model.displayPath(root.path))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.displayPath(root.path))
                    Spacer(minLength: 0)
                    Button {
                        model.removeRoot(root)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isScanning)
                    .help(L("Remove scan folder"))
                    .accessibilityLabel(L("Remove scan folder %@", model.displayPath(root.path)))
                    .accessibilityIdentifier("advisories.agent.remove-root")
                }
            }
            Button {
                guard let root = AdvisoryProjectFolderPicker.chooseAgentRoot() else { return }
                model.addRoot(root)
            } label: {
                Label(L("Add scan folder…"), systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .disabled(model.isScanning)
            .accessibilityIdentifier("advisories.agent.add-root")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("advisories.agent.scan-scope")
    }

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(L("Scan agent files"), systemImage: "folder.badge.gearshape")
                .font(.callout.weight(.medium))
            Text(L("Start an explicit bounded scan of your home folder and any additional folders you selected. Hidden agent folders such as .claude and .codex are included; symlinks, generated folders, and unreadable locations are skipped and reported."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Scan configured folders")) { requestConfiguredScan() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("advisories.agent.scan")
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
        .accessibilityIdentifier("advisories.agent.idle")
    }

    private var scanningCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ProgressView()
            Text(L("Scanning accessible agent metadata in configured folders…"))
                .font(.callout.weight(.medium))
            Text(L("This scan is bounded and can be cancelled. No discovered file is executed."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L("Stop")) { model.cancel() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("advisories.agent.stop")
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
        .accessibilityIdentifier("advisories.agent.scanning")
    }

    private var cancelledCard: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "pause.circle").foregroundStyle(FL.warning)
            Text(L("The agent scan was cancelled. No result is treated as a complete assessment."))
                .font(.callout)
            Spacer(minLength: Spacing.s)
            Button(L("Scan again")) { requestConfiguredScan() }
                .buttonStyle(.borderedProminent)
        }
        .padding(Spacing.m)
        .flCard(radius: Radius.chip)
        .accessibilityIdentifier("advisories.agent.cancelled")
    }

    private func resultContent(_ result: AgentAdvisoryScanResult) -> some View {
        let visible = findings
        return VStack(alignment: .leading, spacing: Spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.m) {
                    findingsTitle
                    Spacer(minLength: 0)
                    filters
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    findingsTitle
                    filters
                }
            }
            if visible.isEmpty {
                ContentUnavailableView {
                    Label(result.totalFindingCount == 0 ? L("No findings") : L("No findings in this filter"),
                          systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text(result.totalFindingCount == 0
                         ? L("Review scan coverage for the locations and files that were inspected.")
                         : L("Try another severity or surface filter."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    findingsTable(visible)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
        }
    }

    private var findingsTitle: some View {
        Text(L("Findings")).font(.headline).fixedSize().accessibilityAddTraits(.isHeader)
    }

    private var filters: some View {
        HStack(spacing: Spacing.m) {
            Picker(L("Severity"), selection: $severityFilter) {
                ForEach(SeverityFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Picker(L("Surface"), selection: $categoryFilter) {
                ForEach(CategoryFilter.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
        }
        .accessibilityIdentifier("advisories.agent.filters")
    }

    private func findingsTable(_ visible: [AgentAdvisoryFinding]) -> some View {
        Table(visible, selection: $selectedFindingID) {
            TableColumn(L("Agent")) { finding in
                Text(verbatim: finding.agent).lineLimit(1)
            }
            .width(min: 76, ideal: 115)
            TableColumn(L("Finding")) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.title).lineLimit(1).help(finding.title)
                    Text(categoryTitle(finding.category))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .width(min: 180, ideal: 260)
            TableColumn(L("Severity")) { finding in
                AgentAdvisorySeverityBadge(severity: finding.severity)
            }
            .width(min: 82, ideal: 110)
            TableColumn(L("Source")) { finding in
                Text(verbatim: finding.source).font(.caption.monospaced()).lineLimit(1)
                    .truncationMode(.middle).help(finding.source)
            }
            .width(min: 155, ideal: 260)
        }
        .accessibilityIdentifier("advisories.agent.findings")
    }

    private func overview(_ result: AgentAdvisoryScanResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Text(L("Scan overview"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: requestConfiguredScan) {
                    Label(L("Scan again"), systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("advisories.agent.rescan")
            }
            summary(result)
            Divider()
            resultBanner(result)
            Text(L("Supported settings inspected: %lld of %lld found", result.settingsInspected, result.settingsPresent))
                .font(.caption).foregroundStyle(.secondary)
            if result.omittedFindings > 0 {
                AdvisoryStatusLine(title: L("Findings hidden by the display limit: %lld", result.omittedFindings),
                                   systemImage: "line.3.horizontal.decrease.circle", tint: FL.warning)
            }
            riskSignals(result)
            AdvisoryOverviewDisclosure(title: analysisMode == .appleOnDevice ? L("Scan coverage and analysis") : L("Scan coverage"),
                                       expanded: $showsCoverage, identifier: "advisories.agent.coverage.disclosure") {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    sourceDisclosure(result)
                    if analysisMode == .appleOnDevice { analysisCard }
                    Text(L("The scan is local, bounded, and metadata-only. It treats discovered instructions as untrusted data, never executes them, and never sends inventory to the advisory service."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(Spacing.m)
        .flCard(radius: Radius.chip)
    }

    private func resultBanner(_ result: AgentAdvisoryScanResult) -> some View {
        let complete = result.complete
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            AdvisoryStatusLine(title: complete ? L("Agent metadata scan complete") : L("Agent metadata scan is incomplete"),
                               systemImage: complete ? "checkmark.shield" : "exclamationmark.triangle",
                               tint: complete ? FL.good : FL.warning)
            if !complete {
                Text(L("Some locations were inaccessible or a scan limit was reached. This is not a safety claim."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("advisories.agent.status")
    }

    private func riskSignals(_ result: AgentAdvisoryScanResult) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.l) { signalLabels(result) }
            VStack(alignment: .leading, spacing: Spacing.xs) { signalLabels(result) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.agent.risk-signals")
    }

    @ViewBuilder
    private func signalLabels(_ result: AgentAdvisoryScanResult) -> some View {
        riskSignal(L("Private data access"), result.privateDataAccess, "lock.document", FL.warning)
        riskSignal(L("Untrusted content"), result.untrustedContent, "text.badge.xmark", FL.warning)
        riskSignal(L("External egress"), result.externalEgress, "arrow.up.right.circle", FL.critical)
    }

    private func riskSignal(_ title: String, _ present: Bool, _ image: String, _ tint: Color) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: image).foregroundStyle(present ? tint : .secondary).accessibilityHidden(true)
            Text(title).fontWeight(.medium)
            Text(present ? L("Observed") : L("Not observed")).foregroundStyle(.secondary)
        }
        .font(.caption2)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(L("Apple on-device model"), systemImage: "sparkles")
                .font(.callout.weight(.medium))
            switch model.analysis {
            case .idle, .analyzing:
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(L("Reviewing scan evidence on this Mac…"))
                }
            case .noEvidence:
                Text(L("No evidence available for model analysis."))
            case .unavailable(let reason):
                Text(reason)
                Text(L("The inventory is available below."))
            case .failed:
                Text(L("The on-device model couldn't finish this analysis."))
                Text(L("The inventory is available below."))
            case .complete(let summary):
                Text(verbatim: summary.text)
                    .textSelection(.enabled)
                Text(L("Evidence: %@", summary.categories.map(categoryTitle).joined(separator: ", ")))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("advisories.agent.model-status")
    }

    private func categoryTitle(_ category: AgentAdvisoryFinding.Category) -> String {
        switch category {
        case .artifact: return L("Artifact")
        case .provenance: return L("Provenance")
        default: return CategoryFilter(rawValue: category.rawValue)?.title ?? L("Agent finding")
        }
    }

    private func summary(_ result: AgentAdvisoryScanResult) -> some View {
        let inspected = result.sources.reduce(0) { $0 + $1.filesRead }
        let high = result.observedEvidence.reduce(0) { $0 + ($1.severity >= .high ? $1.count : 0) }
        let agents = result.inspectedEcosystems.count
        return HStack(spacing: Spacing.m) {
            AdvisoryOverviewMetric(title: L("Findings"), value: result.totalFindingCount)
            Divider().frame(height: 32)
            AdvisoryOverviewMetric(title: L("High / critical"), value: high,
                                   icon: high > 0 ? "exclamationmark.triangle.fill" : nil, tint: FL.critical)
            Divider().frame(height: 32)
            AdvisoryOverviewMetric(title: L("Agent ecosystems"), value: agents)
            Divider().frame(height: 32)
            AdvisoryOverviewMetric(title: L("Files inspected"), value: inspected)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceDisclosure(_ result: AgentAdvisoryScanResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L("Scan coverage")).font(.callout.weight(.semibold))
            if !result.inspectedEcosystems.isEmpty {
                Text(result.inspectedEcosystems.map(ecosystemName).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(result.sources) { source in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Image(systemName: source.status == .complete ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(source.status == .complete ? FL.good : FL.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.root)
                        Text(L("%lld directories · %lld candidates · %lld bytes", source.directoriesVisited,
                               source.candidateFiles, source.bytesRead))
                            .font(.caption).foregroundStyle(.secondary)
                        if !source.reasons.isEmpty {
                            Text(source.reasons.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(FL.warning)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(source.status == .complete ? L("Complete") : L("Limited"))
                        .font(.caption).foregroundStyle(source.status == .complete ? FL.good : FL.warning)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("advisories.agent.coverage")
    }

    private func ecosystemName(_ id: String) -> String {
        switch id {
        case "zed": return "Zed"
        case "vscode": return "Visual Studio Code"
        case "continue": return "Continue"
        case "agents": return "AGENTS.md"
        default: return AgentCatalog.knownAgent(identity: id)?.name ?? id
        }
    }

    private func requestConfiguredScan() {
        if homeScanConsent {
            model.startConfiguredScan()
        } else {
            requestHomeConsent = true
        }
    }

}

private struct AgentAdvisorySeverityBadge: View {
    let severity: AgentAdvisoryFinding.Severity

    var body: some View {
        Label {
            Text(severity.title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch severity {
        case .critical, .high: return "exclamationmark.triangle.fill"
        case .medium: return "questionmark.circle"
        case .low, .info: return "info.circle"
        }
    }

    private var tint: Color {
        switch severity {
        case .critical, .high: return FL.critical
        case .medium: return FL.warning
        case .low: return FL.accent
        case .info: return .secondary
        }
    }
}

private struct AgentAdvisoryFindingDetail: View {
    let finding: AgentAdvisoryFinding
    let category: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header
                    context
                    Divider()
                    VStack(alignment: .leading, spacing: Spacing.l) {
                        guidance(L("Why it matters"), finding.explanation, icon: "info.circle", tint: FL.muted)
                        guidance(L("Recommended action"), finding.remediation, icon: "checklist", tint: FL.accent)
                    }
                    .accessibilityIdentifier("advisories.agent.detail.guidance")
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
        .frame(width: 580, height: 360)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.agent.detail")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2.weight(.medium))
                .foregroundStyle(FL.accent)
                .frame(width: 40, height: 40)
                .background(FL.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip))
                .accessibilityHidden(true)
            Text(finding.title)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            AgentAdvisorySeverityBadge(severity: finding.severity)
                .fixedSize()
                .accessibilityIdentifier("advisories.agent.detail.severity")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.agent.detail.identity")
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                metadata(L("Agent"), finding.agent)
                metadata(L("Category"), category)
                metadata(L("Surface"), finding.surface.title)
            }
            Divider()
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(L("Source"), systemImage: "doc.text")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(verbatim: finding.source)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("advisories.agent.detail.source")
            }
        }
        .padding(Spacing.m)
        .flCard(radius: Radius.chip)
    }

    private func metadata(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: value).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func guidance(_ title: String, _ body: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(verbatim: body).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
