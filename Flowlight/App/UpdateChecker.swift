import AppKit
import CryptoKit
import Foundation

/// A published GitHub release, reduced to what the updater needs.
struct AppRelease: Equatable, Sendable {
    var version: String          // "0.1.2" (tag without the leading "v")
    var name: String
    var notes: String            // Markdown body
    var pageURL: URL
    var dmgURL: URL?
    var checksumsURL: URL?
    var publishedAt: Date?

    /// Parses `GET /repos/{owner}/{repo}/releases/latest`. Drafts and pre-releases are rejected.
    static func parse(_ data: Data) throws -> AppRelease {
        struct Asset: Decodable { var name: String; var browser_download_url: URL }
        struct Payload: Decodable {
            var tag_name: String; var name: String?; var body: String?; var html_url: URL
            var draft: Bool?; var prerelease: Bool?; var published_at: String?; var assets: [Asset]
        }
        let p = try JSONDecoder().decode(Payload.self, from: data)
        guard p.draft != true, p.prerelease != true else { throw UpdateError.noRelease }
        let dmg = p.assets.first { $0.name == "Flowlight.dmg" } ?? p.assets.first { $0.name.hasSuffix(".dmg") }
        let sums = p.assets.first { $0.name == "SHA256SUMS.txt" }
        let date = p.published_at.flatMap { ISO8601DateFormatter().date(from: $0) }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        return AppRelease(version: version, name: p.name ?? "Flowlight \(version)", notes: p.body ?? "", pageURL: p.html_url,
                          dmgURL: dmg?.browser_download_url, checksumsURL: sums?.browser_download_url, publishedAt: date)
    }
}

enum UpdateError: LocalizedError, Equatable {
    case noRelease, badResponse(Int), checksumMismatch, noDownload

    var errorDescription: String? {
        switch self {
        case .noRelease: return "No published release was found."
        case .badResponse(let code): return code == 403 ? "GitHub is rate-limiting update checks. Try again later." : "GitHub returned HTTP \(code)."
        case .checksumMismatch: return "The download didn't match its published checksum, so it wasn't opened."
        case .noDownload: return "This release has no disk image to download."
        }
    }
}

enum VersionCompare {
    /// Numeric dotted comparison ("0.10.0" > "0.9.3"); pre-release suffixes ("-beta") are ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The SHA-256 listed for `fileName` in a `shasum -a 256` style file.
    static func checksum(for fileName: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields.last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == fileName {
                return String(fields[0]).lowercased()
            }
        }
        return nil
    }
}

/// Checks GitHub Releases for a newer Flowlight and fetches the disk image on request.
/// It makes one anonymous HTTPS request per check (no cookies, no identifiers beyond what any
/// request carries: IP address and a `Flowlight/<version>` user agent), and it can be turned off.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle, checking, upToDate, available(AppRelease), downloading(Double), failed(String)
    }

    enum Keys {
        static let automatic = "updates.automatic"
        static let lastCheck = "updates.lastCheck"
        static let skipped = "updates.skippedVersion"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: AppRelease?
    @Published var showWindow = false

    let currentVersion: String
    let repository: String
    private var timer: Timer?
    private var downloadTask: Task<Void, Never>?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpAdditionalHeaders = ["User-Agent": "Flowlight/\(currentVersion)", "Accept": "application/vnd.github+json"]
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        repository = bundle.object(forInfoDictionaryKey: "FLUpdateRepository") as? String ?? "xinbetween/flowlight"
        UserDefaults.standard.register(defaults: [Keys.automatic: true])
    }

    var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.automatic) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.automatic); objectWillChange.send(); schedule() }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: Keys.lastCheck) as? Date }

    /// A newer release the user hasn't chosen to skip.
    var pendingUpdate: AppRelease? {
        guard case .available(let release) = state,
              UserDefaults.standard.string(forKey: Keys.skipped) != release.version else { return nil }
        return release
    }

    func start() {
        guard !DemoData.isEnabled else { return }
        schedule()
        guard automatic else { return }
        // Shortly after launch, unless we checked within the last 12 hours.
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 12 * 3600 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            Task { await self?.check(userInitiated: false) }
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        state = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
            let (data, response) = try await session.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw code == 404 ? UpdateError.noRelease : UpdateError.badResponse(code) }
            let release = try AppRelease.parse(data)
            latest = release
            UserDefaults.standard.set(Date(), forKey: Keys.lastCheck)
            if VersionCompare.isNewer(release.version, than: currentVersion) {
                state = .available(release)
                // A user-initiated check always shows the window; background checks only for unskipped versions.
                if userInitiated || pendingUpdate != nil { showWindow = true }
            } else {
                state = .upToDate
                if userInitiated { showWindow = true }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { showWindow = true }
        }
    }

    func skip(_ release: AppRelease) {
        UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        showWindow = false
        objectWillChange.send()
    }

    /// Downloads the DMG to ~/Downloads, verifies it against SHA256SUMS.txt when the release has one, and opens it.
    func downloadAndOpen(_ release: AppRelease) {
        guard let dmgURL = release.dmgURL else { state = .failed(UpdateError.noDownload.localizedDescription); return }
        downloadTask?.cancel()
        state = .downloading(0)
        downloadTask = Task {
            do {
                let (temp, response) = try await session.download(from: dmgURL, delegate: nil)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { throw UpdateError.badResponse(code) }
                if let sumsURL = release.checksumsURL {
                    let (sums, _) = try await session.data(from: sumsURL)
                    let expected = VersionCompare.checksum(for: dmgURL.lastPathComponent, in: String(decoding: sums, as: UTF8.self))
                    let actual = SHA256.hash(data: try Data(contentsOf: temp)).map { String(format: "%02x", $0) }.joined()
                    guard expected == nil || expected == actual else { throw UpdateError.checksumMismatch }
                }
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let destination = downloads.appendingPathComponent("Flowlight-\(release.version).dmg")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                state = .available(release)
                NSWorkspace.shared.open(destination)
            } catch is CancellationError {
                state = .available(release)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
