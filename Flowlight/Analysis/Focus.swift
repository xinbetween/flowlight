import Foundation
import SwiftUI

/// One thing worth watching while Focus is on: an app, or a destination.
struct FocusTarget: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case app, host }
    var kind: Kind
    /// Bundle identifier for `.app`; a hostname or IP address for `.host`.
    var value: String
    /// What the UI shows: the app's name, or the pattern itself.
    var label: String
    var id: String { "\(kind.rawValue):\(value)" }

    static func app(_ bundleID: String, name: String) -> FocusTarget? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        return FocusTarget(kind: .app, value: id, label: name.isEmpty ? id : name)
    }

    /// Cleans typed input the way allowlists do. CIDR ranges are refused: Focus has to mean the same thing in
    /// SQL as it does in the live feed, and SQLite can't match a range against a stored address.
    static func host(_ input: String) -> FocusTarget? {
        guard let host = AgentPolicy.normalize(input), !AgentPolicy.isCIDR(host) else { return nil }
        return FocusTarget(kind: .host, value: host, label: host)
    }
}

/// Focus without the observable model around it, so database queries and the live pipeline can match against it.
/// A record is in scope when it matches *any* target — apps and destinations are a union, not an intersection.
struct FocusScope: Equatable, Sendable {
    var bundleIDs: [String] = []
    var hosts: [String] = []

    static let none = FocusScope()
    var isEmpty: Bool { bundleIDs.isEmpty && hosts.isEmpty }

    init(bundleIDs: [String] = [], hosts: [String] = []) {
        self.bundleIDs = bundleIDs
        self.hosts = hosts
    }

    init(_ targets: [FocusTarget]) {
        bundleIDs = targets.filter { $0.kind == .app }.map(\.value)
        hosts = targets.filter { $0.kind == .host }.map(\.value)
    }

    func matches(bundleID: String, domain: String, remoteIP: String) -> Bool {
        if bundleIDs.contains(bundleID) { return true }
        return hosts.contains { AgentPolicy.matches($0, host: domain, ip: remoteIP) }
    }
}

/// Focus mode: while it's on, every screen shows only the apps and destinations listed here.
///
/// It filters what you see, never what's recorded. History stays complete, so turning Focus off shows the traffic
/// it was hiding, and the anomaly baselines keep learning from everything.
@MainActor
final class FocusStore: ObservableObject {
    enum Keys {
        static let isOn = "focus.on"
        static let targets = "focus.targets"
    }

    @Published var isOn: Bool { didSet { guard isOn != oldValue else { return }; save() } }
    @Published var targets: [FocusTarget] { didSet { guard targets != oldValue else { return }; save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Keys.isOn)
        targets = (defaults.data(forKey: Keys.targets)).flatMap { try? JSONDecoder().decode([FocusTarget].self, from: $0) } ?? []
    }

    /// The scope queries should use: empty while Focus is off, which every filter treats as "show everything".
    var scope: FocusScope { isOn ? FocusScope(targets) : .none }

    var apps: [FocusTarget] { targets.filter { $0.kind == .app } }
    var hosts: [FocusTarget] { targets.filter { $0.kind == .host } }

    /// On with nothing listed would hide every screen, so it reads as off until something is added.
    var isActive: Bool { isOn && !targets.isEmpty }

    var summary: String {
        let apps = apps.count, hosts = hosts.count
        switch (apps, hosts) {
        case (0, 0): return "Nothing chosen yet"
        case (_, 0): return apps == 1 ? "1 app" : "\(apps) apps"
        case (0, _): return hosts == 1 ? "1 destination" : "\(hosts) destinations"
        default: return "\(apps) app\(apps == 1 ? "" : "s"), \(hosts) destination\(hosts == 1 ? "" : "s")"
        }
    }

    func contains(_ target: FocusTarget) -> Bool { targets.contains { $0.id == target.id } }

    /// Adds a target and turns Focus on — choosing something to focus on is the same gesture as focusing.
    func add(_ target: FocusTarget) {
        if !contains(target) { targets.append(target) }
        isOn = true
    }

    func remove(_ target: FocusTarget) {
        targets.removeAll { $0.id == target.id }
    }

    /// What the "Focus on this" menu item should do for something already listed: drop it again.
    func toggle(_ target: FocusTarget) {
        if contains(target) { remove(target) } else { add(target) }
    }

    func clear() {
        targets = []
        isOn = false
    }

    private func save() {
        defaults.set(isOn, forKey: Keys.isOn)
        defaults.set(try? JSONEncoder().encode(targets), forKey: Keys.targets)
    }
}
