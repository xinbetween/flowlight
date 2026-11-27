import AppKit

/// Presents the bounded, user-consent folder picker used by both Advisories and Settings.
/// The selected folder is the only root from which package manifests may be inspected.
enum AdvisoryProjectFolderPicker {
    @MainActor
    static func choose() -> AdvisoryInventoryRoot? {
        choose(message: L("Choose an additional project folder. Flowlight also scans bounded package metadata throughout your home folder, while skipping system, generated, and cache folders."))
    }

    @MainActor
    static func chooseAgentRoot() -> AdvisoryInventoryRoot? {
        choose(message: L("Choose an additional folder for local agent settings scans."))
    }

    @MainActor
    private static func choose(message: String) -> AdvisoryInventoryRoot? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose")
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let standardizedURL = url.standardizedFileURL
        let bookmark = try? standardizedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return AdvisoryInventoryRoot(
            path: standardizedURL.path,
            userSelected: true,
            bookmarkData: bookmark
        )
    }
}
