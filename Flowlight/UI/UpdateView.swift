import SwiftUI

/// The Software Update window: what's new, and a verified download.
struct UpdateView: View {
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }

            if let release = shownRelease {
                ScrollView {
                    Text(notes(release))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(height: 230)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            if case .downloading = updater.state {
                ProgressView("Downloading and verifying…").controlSize(.small)
            }
            if case .installing = updater.state {
                ProgressView("Preparing the update. Flowlight will quit and reopen…").controlSize(.small)
            }
            if case .failed(let message) = updater.state {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }

            HStack {
                if case .available(let release) = updater.state {
                    Button("Skip This Version") { updater.skip(release); dismissWindow(id: "update") }
                    Spacer()
                    Button("View on GitHub") { NSWorkspace.shared.open(release.pageURL) }
                    Button("Remind Me Later") { dismissWindow(id: "update") }
                    Button("Download") { updater.download(release) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isDownloading)
                } else if case .ready(let release, let dmg) = updater.state {
                    Button("Open Disk Image") { updater.openDiskImage() }
                    Spacer()
                    Button("Install Later") { dismissWindow(id: "update") }
                    Button("Quit & Install") { updater.installAndRelaunch(release, dmg: dmg) }
                        .keyboardShortcut(.defaultAction)
                } else if case .installing = updater.state {
                    Spacer()
                } else if case .downloading = updater.state {
                    Spacer()
                } else if case .checking = updater.state {
                    ProgressView().controlSize(.small)
                    Spacer()
                } else {
                    if updater.downloadedDMG != nil {
                        Button("Open Disk Image") { updater.openDiskImage() }
                    }
                    Spacer()
                    Button("Check Again") { Task { await updater.check(userInitiated: true) } }
                    Button("OK") { dismissWindow(id: "update") }.keyboardShortcut(.defaultAction)
                }
            }

            if let hint {
                Text(hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var shownRelease: AppRelease? {
        switch updater.state {
        case .available(let r), .ready(let r, _), .installing(let r): return r
        case .downloading: return updater.latest
        default: return nil
        }
    }

    private var hint: String? {
        switch updater.state {
        case .available:
            return "Flowlight downloads the update and checks it against the release's published SHA-256. Nothing is installed until you choose."
        case .ready:
            return "Flowlight needs to quit to finish. It replaces itself and reopens, keeping your history and settings. Choose Install Later to keep using it now."
        case .failed where updater.downloadedDMG != nil:
            return "You can still install by hand: quit Flowlight, then drag the new version from the disk image into Applications."
        default:
            return nil
        }
    }

    private var isDownloading: Bool {
        if case .downloading = updater.state { return true }
        return false
    }

    private var headline: String {
        switch updater.state {
        case .available(let r): return "Flowlight \(r.version) is available"
        case .downloading: return "Downloading Flowlight \(updater.latest?.version ?? "")"
        case .ready(let r, _): return "Flowlight \(r.version) is ready to install"
        case .installing(let r): return "Installing Flowlight \(r.version)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "Flowlight is up to date"
        case .failed: return updater.downloadedDMG == nil ? "Couldn't check for updates" : "The update didn't finish"
        case .idle: return "Software Update"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .available: return "You have \(updater.currentVersion)."
        case .upToDate: return "Version \(updater.currentVersion) is the latest release."
        default: return "You have \(updater.currentVersion)."
        }
    }

    private func notes(_ release: AppRelease) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = ReleaseNotes.readable(release.notes)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum ReleaseNotes {
    /// The first meaningful line of the notes, for a notification body.
    static func headline(_ markdown: String) -> String? {
        for line in readable(markdown).components(separatedBy: "\n") {
            let text = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "•  ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if text.count > 12 { return String(text.prefix(160)) }
        }
        return nil
    }

    /// Release-note Markdown made readable in a plain text view: headings become bold lines, bullets get "•",
    /// and everything from the checksum section on is dropped (it's for verification, not reading).
    static func readable(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("### checksums") || line.lowercased().hasPrefix("## checksums") { break }
            if line.hasPrefix("```") { continue }
            if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                lines.append("**" + line[heading.upperBound...] + "**")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append("•  " + line.dropFirst(2))
            } else {
                lines.append(raw)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
