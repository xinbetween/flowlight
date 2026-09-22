import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case live, agents, reports, alerts, capture
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: return "Live"
        case .agents: return "AI Agents"
        case .reports: return "Reports"
        case .alerts: return "Alerts"
        case .capture: return "Capture"
        }
    }
    var icon: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .agents: return "sparkles"
        case .reports: return "chart.bar.xaxis"
        case .alerts: return "exclamationmark.triangle"
        case .capture: return "antenna.radiowaves.left.and.right"
        }
    }
    var shortcut: KeyEquivalent { KeyEquivalent(Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1))) }
}

/// A request from another screen to open Reports with a given scope.
struct ReportRequest: Equatable {
    var filter: TrafficFilter
    var granularity: Granularity?
    var end: Date?
    var id = UUID()
}

/// Shared navigation state so screens can link to each other (Live/Alerts → Reports).
@MainActor
final class AppNavigation: ObservableObject {
    @Published var selection: SidebarItem = .live
    @Published var reportRequest: ReportRequest?

    func showReport(filter: TrafficFilter, granularity: Granularity? = nil, end: Date? = nil) {
        reportRequest = ReportRequest(filter: filter, granularity: granularity, end: end)
        selection = .reports
    }
}
