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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    explanationCard
                    scanScopeCard
                    switch model.phase {
                    case .idle:
                        idleCard
                    case .scanning:
                        scanningCard
                    case .cancelled:
                        cancelledCard
                    case .complete:
                        if let scanResult {
                            resultContent(scanResult, height: geometry.size.height)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
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
        .sheet(item: selectedBinding) { finding in
            AgentAdvisoryFindingDetail(finding: finding)
        }
        .accessibilityIdentifier("advisories.agent")
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(L("Agent security inventory"), systemImage: "shield.lefthalf.filled")
                .font(.title3.weight(.semibold))
            Text(L("Find agent instructions, skills, hooks, MCP servers, plugins, permissions, gateways, and credential-like configuration stored on this Mac."))
                .font(.callout)
            Text(L("The scan is local, bounded, and metadata-only. It treats discovered instructions as untrusted data, never executes them, and never sends inventory to the advisory service."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard()
        .accessibilityIdentifier("advisories.agent.explanation")
    }

    private var scanScopeCard: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(L("Agent scan folders"), systemImage: "folder.badge.gearshape")
                .font(.callout.weight(.medium))
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
                    Text(model.displayPath(root.path))
                        .font(.caption.monospaced())
                        .lineLimit(1)
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
            Picker(L("Advisory analysis"), selection: $analysisMode) {
                ForEach(AgentAdvisoryAnalysisMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .fixedSize()
            .accessibilityIdentifier("advisories.agent.model")
            Button(L("Scan configured folders")) { requestConfiguredScan() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning)
                .accessibilityIdentifier("advisories.agent.rescan")
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
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

    private func resultContent(_ result: AgentAdvisoryScanResult, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            resultBanner(result)
            riskSignals(result)
            summary(result)
            if analysisMode == .appleOnDevice { analysisCard }
            HStack(spacing: Spacing.s) {
                Picker(L("Severity"), selection: $severityFilter) {
                    ForEach(SeverityFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("Surface"), selection: $categoryFilter) {
                    ForEach(CategoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 210)
                Spacer(minLength: 0)
                Button(L("Clear")) { model.clear() }
                    .buttonStyle(.bordered)
            }
            .accessibilityIdentifier("advisories.agent.filters")
            if findings.isEmpty {
                ContentUnavailableView {
                    Label(L("No findings in this filter"), systemImage: "checkmark.shield")
                } description: {
                    Text(L("No finding is proof of safety when coverage is incomplete; review the scan status above."))
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                Table(findings, selection: $selectedFindingID) {
                    TableColumn(L("Agent")) { finding in
                        Text(finding.agent).lineLimit(1)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn(L("Finding")) { finding in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).lineLimit(1)
                            Text(finding.category.rawValue.uppercased())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 180, ideal: 260)
                    TableColumn(L("Severity")) { finding in
                        FLPill(text: finding.severity.title, systemImage: severityIcon(finding.severity),
                               color: severityColor(finding.severity))
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn(L("Source")) { finding in
                        Text(finding.source).font(.caption.monospaced()).lineLimit(1)
                    }
                    .width(min: 180, ideal: 260)
                }
                .frame(minHeight: 220, maxHeight: max(220, height - 520))
                .accessibilityIdentifier("advisories.agent.findings")
            }
            sourceDisclosure(result)
        }
    }

    private func resultBanner(_ result: AgentAdvisoryScanResult) -> some View {
        let complete = result.complete
        return HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: complete ? "checkmark.shield" : "exclamationmark.triangle")
                .foregroundStyle(complete ? FL.good : FL.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(complete ? L("Agent metadata scan complete") : L("Agent metadata scan is incomplete"))
                    .font(.callout.weight(.medium))
                Text(complete
                     ? L("Accessible candidate files were inspected within the configured bounds.")
                     : L("Some locations were inaccessible or a scan limit was reached. This is not a safety claim."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((complete ? FL.good : FL.warning).opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.chip))
        .accessibilityIdentifier("advisories.agent.status")
    }

    private func riskSignals(_ result: AgentAdvisoryScanResult) -> some View {
        HStack(spacing: Spacing.s) {
            riskTile(L("Private data access"), result.privateDataAccess, "lock.document", FL.warning)
            riskTile(L("Untrusted content"), result.untrustedContent, "text.badge.xmark", FL.warning)
            riskTile(L("External egress"), result.externalEgress, "arrow.up.right.circle", FL.critical)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("advisories.agent.risk-signals")
    }

    private func riskTile(_ title: String, _ present: Bool, _ image: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: image).foregroundStyle(present ? tint : FL.good)
            Text(title).font(.caption.weight(.medium))
            Text(present ? L("Observed") : L("Not observed"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
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
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
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
        return HStack(spacing: Spacing.s) {
            StatTile(title: L("Findings"), value: "\(result.totalFindingCount)", systemImage: "flag")
            StatTile(title: L("High / critical"), value: "\(high)", systemImage: "exclamationmark.triangle",
                     tint: high > 0 ? FL.critical : .secondary)
            StatTile(title: L("Agent ecosystems"), value: "\(agents)", systemImage: "sparkles")
            StatTile(title: L("Files inspected"), value: "\(inspected)", systemImage: "doc.text.magnifyingglass")
        }
    }

    private func sourceDisclosure(_ result: AgentAdvisoryScanResult) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(L("Scan coverage")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(L("Supported settings inspected: %lld of %lld found", result.settingsInspected, result.settingsPresent))
                .font(.caption.weight(.medium))
            if !result.inspectedEcosystems.isEmpty {
                Text(result.inspectedEcosystems.map(ecosystemName).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.omittedFindings > 0 {
                Text(L("Findings hidden by the display limit: %lld", result.omittedFindings))
                    .font(.caption).foregroundStyle(FL.warning)
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
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard(radius: Radius.chip)
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

    private func severityIcon(_ severity: AgentAdvisoryFinding.Severity) -> String {
        severity >= .high ? "exclamationmark.triangle.fill" : severity == .medium ? "questionmark.circle" : "info.circle"
    }

    private func severityColor(_ severity: AgentAdvisoryFinding.Severity) -> Color {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    FLContextRow(title: finding.title,
                                 details: [finding.agent, finding.source,
                                           finding.category.rawValue.uppercased(), finding.surface.title],
                                 systemImage: "shield.lefthalf.filled",
                                 tint: finding.severity >= .high ? FL.critical : FL.warning,
                                 identifier: "advisories.agent.detail.identity")
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(L("Why it matters")).font(.headline)
                        Text(finding.explanation)
                        Text(L("Recommended action")).font(.headline)
                        Text(finding.remediation)
                    }
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flCard()
                    .accessibilityIdentifier("advisories.agent.detail.guidance")
                }
                .padding(Spacing.l)
            }
            .navigationTitle(L("Agent finding"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}
