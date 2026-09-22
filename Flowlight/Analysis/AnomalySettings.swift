import Foundation

/// User-tunable anomaly thresholds, persisted in UserDefaults (see SettingsView).
struct AnomalySettings: Sendable {
    var sigma: Double = 3
    var minHourlySamples = 24
    var minDailySamples = 7
    var learningPeriod: TimeInterval = 24 * 3600
    var minAlertBytes: Int64 = 1_000_000
    var idleMinutes: Double = 10
    var idleUploadBytesPerMinute: Int64 = 5_000_000
    var alertFirstContact = true
    var alertNonStandardPorts = true
    // AI agents
    var agentLearningPeriod: TimeInterval = 3600
    var agentSensitiveChannels = true
    var agentUnnamedHosts = true
    var agentEgressBytesPerHour: Int64 = 100_000_000
    var agentWhileAway = true
    var agentAwayMinutes: Double = 15
    var agentAwayBytes: Int64 = 1_000_000

    enum Keys {
        static let sigma = "anomaly.sigma"
        static let learningHours = "anomaly.learningHours"
        static let minAlertMB = "anomaly.minAlertMB"
        static let idleMinutes = "anomaly.idleMinutes"
        static let idleUploadMB = "anomaly.idleUploadMB"
        static let firstContact = "anomaly.firstContact"
        static let nonStandardPorts = "anomaly.nonStandardPorts"
        static let notifications = "alerts.notifications"
        static let retentionHours = "storage.secondRetentionHours"
        static let captureMode = "capture.mode"
        static let agentSensitive = "agents.sensitiveChannels"
        static let agentUnnamed = "agents.unnamedHosts"
        static let agentEgressMB = "agents.egressMBPerHour"
        static let agentAway = "agents.whileAway"
        static let agentAwayMinutes = "agents.awayMinutes"
        static let menuBarRates = "menubar.showRates"
        static let ownerLookup = "enrichment.ownerLookup"
        static let packetCapture = "enrichment.packetCapture"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.sigma: 3.0, Keys.learningHours: 24.0, Keys.minAlertMB: 1.0, Keys.idleMinutes: 10.0,
            Keys.idleUploadMB: 5.0, Keys.firstContact: true, Keys.nonStandardPorts: true,
            Keys.notifications: true, Keys.retentionHours: 6.0,
            Keys.agentSensitive: true, Keys.agentUnnamed: true, Keys.agentEgressMB: 100.0, Keys.agentAway: true,
            Keys.agentAwayMinutes: 15.0, Keys.captureMode: CaptureMode.nettop.rawValue,
            Keys.menuBarRates: true,
            Keys.ownerLookup: false, Keys.packetCapture: true,
        ])
    }

    static var current: AnomalySettings {
        let d = UserDefaults.standard
        var s = AnomalySettings()
        s.sigma = max(1, d.double(forKey: Keys.sigma))
        s.learningPeriod = d.double(forKey: Keys.learningHours) * 3600
        s.minAlertBytes = Int64(d.double(forKey: Keys.minAlertMB) * 1_000_000)
        s.idleMinutes = max(1, d.double(forKey: Keys.idleMinutes))
        s.idleUploadBytesPerMinute = Int64(d.double(forKey: Keys.idleUploadMB) * 1_000_000)
        s.alertFirstContact = d.bool(forKey: Keys.firstContact)
        s.alertNonStandardPorts = d.bool(forKey: Keys.nonStandardPorts)
        s.agentSensitiveChannels = d.bool(forKey: Keys.agentSensitive)
        s.agentUnnamedHosts = d.bool(forKey: Keys.agentUnnamed)
        s.agentEgressBytesPerHour = Int64(d.double(forKey: Keys.agentEgressMB) * 1_000_000)
        s.agentWhileAway = d.bool(forKey: Keys.agentAway)
        s.agentAwayMinutes = max(1, d.double(forKey: Keys.agentAwayMinutes))
        return s
    }
}
