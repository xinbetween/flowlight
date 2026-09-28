import SwiftUI

/// "Inspect this" for a row in Live, Reports or AI Agents.
///
/// Seeing that an app talked to a host and wanting to know what it said is the commonest move there is, and
/// until now it meant switching screen, remembering the name and typing it into a search field. The same shape
/// as `FocusMenuItems` and `RuleMenuItems`: one small view every table can drop into its context menu, so the
/// three screens can't drift into offering three different things.
struct InspectMenuItems: View {
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var monitor: TrafficMonitor
    /// The app the row is about, if it is about one.
    var app: (bundleID: String, name: String)?
    /// The destination the row is about: a hostname or an address.
    var host: String?

    var body: some View {
        // These scope the list rather than search it. The first version put the name in the search field, which
        // also searches response bodies — so "Inspect Claude Code's Traffic" returned every GitHub page whose
        // HTML contains those two words, and the app whose traffic you asked for was nowhere in it.
        // The destination form. Named separately from the app form below because in English the two differ
        // only by word order, which tells a translator nothing about which is which.
        if let host, !host.isEmpty {
            Button(L("Inspect Traffic to %@", host)) { nav.showInspect(host: host) }
                .help(helpText)
        }
        if let app, !app.name.isEmpty {
            Button(L("Inspect %@'s Traffic", app.name)) { nav.showInspect(app: app) }
                .help(helpText)
        }
    }

    /// Says what will happen rather than promising what will be there. Inspect can only show what was
    /// decrypted, and arriving at an empty screen without knowing that is how a feature reads as broken.
    private var helpText: String {
        monitor.inspection.enabled
            // "which is off" attached the clause to the screen, but the screen opens fine — it is HTTPS
            // inspection that is off. And "this" had no antecedent in a tooltip detached from the row.
            ? L("Opens Inspect with the selected name in the search field. Only traffic that went through the proxy can be shown.")
            : L("Opens Inspect. HTTPS inspection is off — nothing has been decrypted yet, so there will be nothing to show.")
    }
}
