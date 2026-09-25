import Foundation

/// A library of rules worth having before anything has gone wrong.
///
/// A template is not a rule: it is a rule with a hole in it, plus the sentence that says what filling the hole
/// would do. Most of the value is in the sentence. Anyone can type `pastebin.com` into the editor; what they
/// can't do from memory is list the fourteen hosts a package install actually reaches, or notice that a weeknight
/// window leaves Saturday afternoon wide open.
///
/// Three things are load-bearing here:
///
/// - **Every template produces complete rules.** A rule that names neither an app nor a destination would decide
///   every connection on the Mac, so `Rule.isComplete` refuses it; a template that shipped one would be a trap.
///   The tests check this for every template, against every shape of subject.
/// - **A domain is only in this file if it was checked.** A wrong entry in a blocklist is worse than a missing
///   one: the missing one leaves a hole someone may notice, the wrong one refuses traffic nobody asked about and
///   sends them looking in the wrong place. Every host here resolved when it was written down, and several that
///   circulate in well-known blocklists were left out because they no longer do. No test can tell you a domain
///   is the right one, so that part is a promise rather than a proof — what the tests do check is that nothing
///   here is redundant, malformed, or something the store would rewrite on the way in.
/// - **A template says what it needs to work.** Everything here is carried out by the Network Extension except
///   the handful that name a method, which only HTTPS inspection can see. Those say so in their own words, not
///   only in the banner at the top of the Rules screen, and a test fails if one of them stops saying it.
///
/// Domains are written as registrable domains wherever the whole domain is the target, because `Rule` already
/// carries subdomains with it — `sentry.io` covers `o12345.ingest.sentry.io`. Where only one host under a domain
/// should be refused, the host is written out in full: `gist.github.com` is a paste site, `github.com` is not.
struct RuleTemplate: Identifiable {
    /// Why someone would come looking. The categories are the five reasons this library exists, not a taxonomy of
    /// the internet.
    enum Category: String, CaseIterable, Identifiable {
        case agents, exfiltration, telemetry, hours, investigation
        var id: String { rawValue }

        var title: String {
            switch self {
            case .agents: return "AI agents"
            case .exfiltration: return "Ways out"
            case .telemetry: return "Telemetry and analytics"
            case .hours: return "Working hours"
            case .investigation: return "One-off investigation"
            }
        }

        /// One line under the heading, so a category is readable without opening anything in it.
        var summary: String {
            switch self {
            case .agents:
                return "What an agent may reach on its own initiative — installs, other models, someone else's repo."
            case .exfiltration:
                return "The short, anonymous routes a file or a secret can leave by. Handy routes, which is the problem."
            case .telemetry:
                return "Measurement that isn't part of what the app does for you."
            case .hours:
                return "A weekly window. Nothing runs outside it."
            case .investigation:
                return "Something turned up in Live and you want it quiet while you work out what it is."
            }
        }

        var symbol: String {
            switch self {
            case .agents: return "cpu"
            case .exfiltration: return "arrow.up.right.square"
            case .telemetry: return "chart.bar"
            case .hours: return "clock"
            case .investigation: return "magnifyingglass"
            }
        }
    }

    /// What a template has to be told before it becomes a rule. A template that needs something and wasn't given
    /// it produces nothing at all, rather than a rule that quietly means more than it says.
    enum Needs {
        case nothing
        case app
        case destination
        case both
    }

    /// What the row it was applied from already knew.
    struct Subject: Equatable {
        var app = ""
        /// What to call the app in the rule's name. The bundle identifier is what matches; this is what reads.
        var appName = ""
        var destination = ""

        init(app: String = "", appName: String = "", destination: String = "") {
            self.app = app
            self.appName = appName.isEmpty ? app : appName
            self.destination = destination
        }

        var hasApp: Bool { !app.isEmpty }
        var hasDestination: Bool { !destination.isEmpty }
    }

    /// What happens when a template is chosen from a table row. Written down rather than guessed, because the
    /// menu has to promise one of them before the click.
    enum Arrival: Equatable {
        /// Saved immediately. Reserved for a single rule that undoes itself — nothing permanent lands unseen.
        case now
        /// Opens the rule editor with the rule already written, to be read and saved.
        case editor
        /// Opens the library on the Rules screen with this template picked out, listing every rule it would add.
        /// Where more than one rule is involved there is no editor to open, so the list is the review.
        case list
    }

    let id: String
    let title: String
    /// What it does and why you would want it, in one line. This is the part people read.
    let summary: String
    let category: Category
    let needs: Needs
    /// Something true and unwelcome about this template: what it breaks, what it can't see, what it only half
    /// covers. Nil where there is genuinely nothing to warn about.
    let caveat: String?
    /// Whether naming an app narrows this template. False means it writes the same rules either way, so a menu
    /// raised from an app row shouldn't imply otherwise.
    let scopesToApp: Bool
    /// Safe to save without a look: it expires by itself, and it is one rule.
    let appliesImmediately: Bool

    private let build: (Subject) -> [Rule]

    init(id: String, title: String, summary: String, category: Category, needs: Needs = .nothing,
         caveat: String? = nil, scopesToApp: Bool = false, appliesImmediately: Bool = false,
         build: @escaping (Subject) -> [Rule]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.needs = needs
        self.caveat = caveat
        self.scopesToApp = needs == .app || needs == .both || scopesToApp
        self.appliesImmediately = appliesImmediately
        self.build = build
    }

    /// The rules this template writes, or none where it wasn't given what it needs.
    func rules(for subject: Subject = Subject()) -> [Rule] {
        guard isSatisfied(by: subject) else { return [] }
        return build(subject).filter(\.isComplete)
    }

    func isSatisfied(by subject: Subject) -> Bool {
        switch needs {
        case .nothing: return true
        case .app: return subject.hasApp
        case .destination: return subject.hasDestination
        case .both: return subject.hasApp && subject.hasDestination
        }
    }

    /// Which halves of Flowlight would have to be running. Derived from the rules themselves rather than declared
    /// by hand, so a template can't claim to do something it didn't write.
    func engines(for subject: Subject = Subject()) -> Set<Rule.Engine> {
        Set(rules(for: fill(subject)).map(\.engine))
    }

    func arrival(for subject: Subject) -> Arrival {
        guard rules(for: subject).count == 1 else { return .list }
        return appliesImmediately ? .now : .editor
    }

    /// Stand-in values, so a template that needs a subject can still be counted and described in the library
    /// before anyone has told it anything. Never saved — `rules(for:)` with a real subject is what lands.
    func fill(_ subject: Subject) -> Subject {
        var filled = subject
        if !filled.hasApp, needs == .app || needs == .both { filled = Subject(app: "an.app", appName: "the app",
                                                                              destination: filled.destination) }
        if !filled.hasDestination, needs == .destination || needs == .both { filled.destination = "example.com" }
        return filled
    }

    /// How many rules this writes, described before it has a subject.
    func ruleCount(for subject: Subject = Subject()) -> Int { rules(for: fill(subject)).count }
}

// MARK: The library

extension RuleTemplate {
    static let all: [RuleTemplate] = agents + exfiltration + telemetry + hours + investigation

    static func inCategory(_ category: Category) -> [RuleTemplate] { all.filter { $0.category == category } }

    /// The templates that make sense for a row, given what the row knew. Two things are left out: anything that
    /// needs a blank the row can't fill, and anything that would ignore the row entirely.
    ///
    /// The second is the interesting one. A whole-Mac template offered from a row about `api.segment.io` is only
    /// worth offering because that host is in it — the row is how someone found the category. Offered from a row
    /// about some other host it would be an item that has nothing to do with what was clicked.
    static func applicable(to subject: Subject) -> [RuleTemplate] {
        all.filter { $0.isSatisfied(by: subject) && $0.speaksTo(subject) }
    }

    private func speaksTo(_ subject: Subject) -> Bool {
        switch needs {
        case .app, .destination, .both: return true
        case .nothing: return scopesToApp && (subject.hasApp || covers(subject.destination))
        }
    }

    /// Whether this template already refuses a destination, asked the way the engine would ask it — so a template
    /// naming `segment.io` is found from a row about `api.segment.io`.
    func covers(_ destination: String) -> Bool {
        guard !destination.isEmpty else { return false }
        let isAddress = AgentPolicy.isIPAddress(destination)
        return rules().contains {
            AgentPolicy.matches($0.destination, host: isAddress ? "" : destination,
                                ip: isAddress ? destination : "")
        }
    }

    // MARK: Building blocks

    /// One block per destination, all sharing a name so the Rules screen reads as a set rather than as nine
    /// unrelated rules someone wrote on the same afternoon.
    private static func blocks(_ destinations: [String], app: Subject, label: String,
                               schedule: Rule.Schedule = Rule.Schedule()) -> [Rule] {
        destinations.map { destination in
            var rule = Rule(action: .block, app: app.app, destination: destination, origin: .preset)
            rule.schedule = schedule
            rule.name = app.hasApp ? "\(app.appName): \(label)" : label
            return rule
        }
    }
}

// MARK: AI agents

extension RuleTemplate {
    /// An agent is a program that decides what to fetch while you are not watching. These are the fetches people
    /// find afterwards and wish they had been asked about: a package nobody chose, a model weight nobody chose, a
    /// write to a repository nobody chose.
    static let agents: [RuleTemplate] = [
        RuleTemplate(
            id: "agent.no-package-registries",
            title: "No package installs",
            summary: "Stops this agent fetching from the public package registries, so a dependency it decided it "
                + "needed can't arrive while you're reading something else.",
            category: .agents, needs: .app,
            caveat: "Registries move their downloads onto CDNs, and a CDN shared with something you do want can't "
                + "be refused separately. This covers the hosts an install talks to directly; a vendored tarball "
                + "from somewhere else is a different route and isn't in here.",
            build: { subject in
                blocks(packageRegistries, app: subject, label: "no package installs")
            }),

        RuleTemplate(
            id: "agent.no-container-or-model-pulls",
            title: "No container images or model weights",
            summary: "Container registries and model hubs, where one command downloads gigabytes and runs it. "
                + "Worth refusing for an agent that has no business doing either.",
            category: .agents, needs: .app,
            caveat: "Homebrew serves its bottles from `ghcr.io`, so this also stops `brew install` for the app "
                + "named — which for an agent is usually the point, but it is worth knowing before it happens.",
            build: { subject in
                blocks(containerAndModelHosts, app: subject, label: "no image or model pulls")
            }),

        RuleTemplate(
            id: "agent.no-other-model-providers",
            title: "No other model providers",
            summary: "Keeps an agent talking to its own provider by refusing the other model APIs, which is how "
                + "you notice a tool quietly routing your prompts somewhere else.",
            category: .agents, needs: .app,
            caveat: "The list names every provider it knows, including whichever one the agent you pick runs on "
                + "— switch that one rule off after adding, or the agent stops working. And a blocklist can only "
                + "name what it knows: the allowlist on the AI Agents screen is the way round that says yes to a "
                + "short list instead of no to a long one.",
            build: { subject in
                blocks(modelProviders, app: subject, label: "no other model providers")
            }),

        RuleTemplate(
            id: "agent.github-read-only",
            title: "GitHub, but read-only",
            summary: "Lets the agent read repositories and issues over the GitHub API while refusing the requests "
                + "that change anything — pushes to the API, comments, releases, workflow runs.",
            category: .agents, needs: .app,
            caveat: "Only HTTPS inspection can do this: refusing one method means reading the request, and the "
                + "Network Extension sees connections rather than requests. With inspection off these rules are "
                + "watched and nothing is refused. Git over SSH is a different protocol and is untouched by them.",
            build: { subject in
                ["POST", "PUT", "PATCH", "DELETE"].map { method in
                    var rule = Rule(action: .block, app: subject.app, destination: "api.github.com", origin: .preset)
                    rule.method = method
                    rule.status = 403
                    rule.name = "\(subject.appName): GitHub read-only"
                    return rule
                }
            }),

    ]

    /// The hosts an install actually talks to. Several ecosystems keep the index and the files on separate
    /// domains, so both are named — blocking only the index leaves a direct file fetch working.
    static let packageRegistries = [
        "npmjs.org",   // registry.npmjs.org
        "registry.yarnpkg.com",
        "pypi.org",
        "files.pythonhosted.org",   // where a wheel actually comes from
        "rubygems.org",
        "crates.io",
        "proxy.golang.org",
        "sum.golang.org",
        "repo1.maven.org",
        "repo.maven.apache.org",
        "nuget.org",
        "packagist.org",
        "cocoapods.org",
        "formulae.brew.sh",   // the index; the bottles are on ghcr.io
    ]

    static let containerAndModelHosts = [
        "registry-1.docker.io",
        "auth.docker.io",
        "index.docker.io",
        "production.cloudflare.docker.com",   // where the layers come from
        "hub.docker.com",
        "ghcr.io",
        "pkg-containers.githubusercontent.com",
        "quay.io",
        "gcr.io",
        "mcr.microsoft.com",
        "public.ecr.aws",
        "huggingface.co",
        "hf.co",   // the short domain, and where the weights are served
        "ollama.com",
        "registry.ollama.ai",
    ]

    /// Model APIs someone else's key might be pointed at. Only the endpoints, not the marketing sites.
    static let modelProviders = [
        "api.openai.com",
        "api.anthropic.com",
        "generativelanguage.googleapis.com",
        "api.mistral.ai",
        "api.cohere.com",
        "api.cohere.ai",
        "api.deepseek.com",
        "api.groq.com",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.replicate.com",
        "api.x.ai",
        "api.perplexity.ai",
        "openrouter.ai",
    ]
}

// MARK: Ways out

extension RuleTemplate {
    /// Every one of these is a service that takes a blob of text or a file from an unauthenticated client and
    /// hands back a URL. That is a useful thing to exist and a bad thing for a program you aren't watching to be
    /// able to reach, which is the whole of the argument.
    static let exfiltration: [RuleTemplate] = [
        RuleTemplate(
            id: "exfil.paste-sites",
            title: "No paste sites",
            summary: "The public paste services: text in, link out, no account needed. The shortest route a "
                + "secret can take off this Mac.",
            category: .exfiltration, needs: .nothing,
            caveat: "`gist.github.com` is in here and the rest of `github.com` is not, so pushing and cloning "
                + "still work. Self-hosted pastebins are, by definition, not on a list.",
            scopesToApp: true,
            build: { subject in blocks(pasteSites, app: subject, label: "no paste sites") }),

        RuleTemplate(
            id: "exfil.webhook-catchers",
            title: "No webhook catchers",
            summary: "Services that hand out a URL and show you what was sent to it. They exist for debugging, "
                + "and they are where stolen credentials go — the npm worm of September 2025 collected what it "
                + "took at a webhook.site address.",
            category: .exfiltration, needs: .nothing,
            caveat: "If you use one of these to debug a webhook, this will stop that working too. Scope it to an "
                + "agent rather than to the whole Mac if so.",
            scopesToApp: true,
            build: { subject in blocks(webhookCatchers, app: subject, label: "no webhook catchers") }),

        RuleTemplate(
            id: "exfil.file-drops",
            title: "No anonymous file drops",
            summary: "Upload-and-share services that need no account. Bigger than a paste and just as anonymous.",
            category: .exfiltration, needs: .nothing,
            caveat: "These services come and go, so a list of them is always a little out of date. It refuses the "
                + "ones that were reachable when it was written.",
            scopesToApp: true,
            build: { subject in blocks(fileDrops, app: subject, label: "no anonymous file drops") }),

        RuleTemplate(
            id: "exfil.tunnels",
            title: "No tunnels out of this Mac",
            summary: "Services that publish something running on localhost at a public URL. A tunnel is an "
                + "inbound route someone opened from the inside, which is why an outbound firewall is where you "
                + "stop it.",
            category: .exfiltration, needs: .nothing,
            caveat: "Tunnelling tools can be self-hosted against your own server, and a private relay isn't on "
                + "any list. This covers the hosted services.",
            scopesToApp: true,
            build: { subject in blocks(tunnelServices, app: subject, label: "no tunnels") }),

        RuleTemplate(
            id: "exfil.transactional-mail",
            title: "No mail-sending services",
            summary: "The hosted mail APIs a program can post a message to with nothing but a key. Mail is the "
                + "oldest way to send yourself a file from someone else's computer.",
            category: .exfiltration, needs: .nothing,
            caveat: "This names mail APIs by host. It cannot block SMTP as a protocol: a rule matches a "
                + "destination, not a port, so a connection to port 25 on a host that isn't listed here looks "
                + "like any other connection.",
            scopesToApp: true,
            build: { subject in blocks(mailServices, app: subject, label: "no mail-sending services") }),

        RuleTemplate(
            id: "exfil.doh-resolvers",
            title: "No DNS over HTTPS",
            summary: "A program that looks names up over HTTPS resolves them out of Flowlight's sight, and "
                + "everything it does afterwards shows in Live as a bare IP address. Refusing the public DoH "
                + "services puts the names back.",
            category: .exfiltration, needs: .nothing,
            caveat: "This names the public DoH services by host, and that is all it can do. Plain DNS on port 53, "
                + "DNS over TLS, and a resolver reached by its IP address are shaped by port and address rather "
                + "than by destination, and a rule matches a destination. Browsers are built to fall back to the "
                + "system resolver when their DoH server is unreachable; something else might just fail.",
            scopesToApp: true,
            build: { subject in blocks(dohResolvers, app: subject, label: "no DNS over HTTPS") }),

        RuleTemplate(
            id: "exfil.consumer-storage",
            title: "No consumer cloud storage",
            summary: "Dropbox, Drive, OneDrive and the rest, for one named app. A sync client belongs on this "
                + "Mac; a coding agent uploading to one does not.",
            category: .exfiltration, needs: .app,
            caveat: "Scoped to one app on purpose. Blocking these for everything would stop the sync clients, the "
                + "browser tabs and anything else that legitimately uses them. Google Drive's API lives on "
                + "`www.googleapis.com` alongside every other Google API, so only `drive.google.com` is named "
                + "here — an upload through the API isn't covered.",
            build: { subject in blocks(consumerStorage, app: subject, label: "no consumer cloud storage") }),
    ]

    static let pasteSites = [
        "pastebin.com",
        "gist.github.com",   // a paste site that happens to live on github.com
        "rentry.co",
        "rentry.org",
        "dpaste.com",
        "dpaste.org",
        "paste.ee",
        "paste.rs",
        "pastes.io",
        "privatebin.net",
        "controlc.com",
        "termbin.com",
        "0x0.st",
        "sprunge.us",
        "hastebin.com",
        "ghostbin.com",
        "justpaste.it",
        "bpa.st",
    ]

    /// Request catchers and out-of-band interaction servers. The second group is what security tooling uses to
    /// prove a callback happened, and what an injection uses for the same reason.
    /// Request catchers, and the out-of-band interaction servers security tooling uses to prove a callback
    /// happened. An injection reaches for them for the same reason: the URL is disposable and the reply is read
    /// somewhere else.
    static let webhookCatchers = [
        "webhook.site",
        "requestbin.com",
        "pipedream.net",   // bins live at <id>.m.pipedream.net
        "requestcatcher.com",
        "beeceptor.com",
        "postb.in",
        "typedwebhook.tools",
        "oast.fun",   // interactsh, which moved off interact.sh
        "oast.pro",
        "oastify.com",   // Burp Collaborator
        "burpcollaborator.net",
        "dnslog.cn",
    ]

    static let fileDrops = [
        "file.io",
        "gofile.io",
        "catbox.moe",   // covers litterbox.catbox.moe
        "tmpfiles.org",
        "temp.sh",
        "uguu.se",
        "oshi.at",
        "filebin.net",
        "pixeldrain.com",
        "krakenfiles.com",
        "send.vis.ee",   // the surviving Firefox Send
        "wetransfer.com",
    ]

    static let tunnelServices = [
        "ngrok.com",
        "ngrok.io",
        "ngrok.app",
        "ngrok-free.app",
        "trycloudflare.com",
        "loca.lt",
        "localtunnel.me",
        "serveo.net",
        "localhost.run",
        "tunnelto.dev",
        "localxpose.io",
        "pinggy.io",
        "zrok.io",
        "bore.pub",
        "expose.dev",
        "pagekite.me",
    ]

    static let mailServices = [
        "api.sendgrid.com",
        "api.mailgun.net",
        "api.postmarkapp.com",
        "api.resend.com",
        "api.mailjet.com",
        "api.brevo.com",
        "api.sparkpost.com",
        "smtp.gmail.com",
        "smtp.sendgrid.net",
        "smtp.mailgun.org",
    ]

    static let dohResolvers = [
        "cloudflare-dns.com",   // covers mozilla. and chrome. , which is how those browsers reach it
        "one.one.one.one",
        "dns.google",
        "dns.quad9.net",
        "doh.opendns.com",
        "dns.nextdns.io",
        "dns.adguard-dns.com",
        "dns.controld.com",
        "doh.mullvad.net",
    ]

    static let consumerStorage = [
        "dropbox.com",
        "dropboxapi.com",
        "drive.google.com",
        "onedrive.live.com",
        "1drv.ms",
        "box.com",
        "mega.nz",
        "mega.co.nz",
        "pcloud.com",
    ]
}

// MARK: Telemetry and analytics

extension RuleTemplate {
    /// Measurement is not malware, and the copy here shouldn't pretend it is. What it is, is traffic that happens
    /// because of how the app was built rather than because of anything you asked it to do — which makes it the
    /// easiest kind to refuse and the easiest kind to be surprised by.
    static let telemetry: [RuleTemplate] = [
        RuleTemplate(
            id: "telemetry.product-analytics",
            title: "No product analytics",
            summary: "The usage-measurement services Mac apps and developer tools send events to. Refusing them "
                + "costs you nothing the app does for you.",
            category: .telemetry, needs: .nothing,
            caveat: "Statsig serves feature flags from the same domains as its analytics, so an app that uses it "
                + "may fall back to its built-in defaults rather than simply measuring less. And some products "
                + "route analytics through their own domain, which is indistinguishable from the rest of what "
                + "they do and so can't be on a list like this at all.",
            scopesToApp: true,
            build: { subject in blocks(analyticsHosts, app: subject, label: "no product analytics") }),

        RuleTemplate(
            id: "telemetry.crash-reporting",
            title: "No crash and error reporting",
            summary: "Sentry, Bugsnag, Crashlytics and the rest. Stack traces sometimes carry file paths, "
                + "environment variables and fragments of what you were working on.",
            category: .telemetry, needs: .nothing,
            caveat: "The honest cost: an app that crashes on you stops being able to tell anyone. If you report "
                + "bugs to a developer you like, this is worth scoping to one app rather than switching on "
                + "everywhere. Firebase also uses `app-measurement.com` as a reachability check, so an app built "
                + "on it may show a connection error rather than simply sending less.",
            scopesToApp: true,
            build: { subject in blocks(crashReportingHosts, app: subject, label: "no crash reporting") }),

        RuleTemplate(
            id: "telemetry.apple",
            title: "No Apple advertising and analytics",
            summary: "The advertising and measurement hosts under `apple.com`, which are separate from everything "
                + "the Mac needs to work: updates, certificates, push and iCloud are all left alone.",
            category: .telemetry, needs: .nothing,
            caveat: "Apple doesn't publish this as a list, so it is compiled from public ones and each host was "
                + "checked by hand — some names that circulate in older blocklists no longer exist. Three things "
                + "are deliberately left out: `xp.apple.com`, which Apple's own enterprise list files under "
                + "software updates as well as metrics; certificate validation, which is what tells your Mac a "
                + "developer certificate has been revoked; and Feedback Assistant, which is a report you chose to "
                + "send.",
            scopesToApp: true,
            build: { subject in blocks(appleTelemetryHosts, app: subject, label: "no Apple advertising or analytics") }),

        RuleTemplate(
            id: "telemetry.attribution",
            title: "No install attribution",
            summary: "The SDKs that exist to work out which advert led to you. They carry a device fingerprint by "
                + "design, and nothing in the app depends on them.",
            category: .telemetry, needs: .nothing,
            caveat: nil,
            scopesToApp: true,
            build: { subject in blocks(attributionHosts, app: subject, label: "no install attribution") }),
    ]

    /// Statsig is the reason a list like this is worth having at all: five of its ingestion domains are named
    /// after nothing, so nobody scanning Live would ever pick them out.
    static let analyticsHosts = [
        "google-analytics.com",
        "analytics.google.com",
        "googletagmanager.com",
        "segment.io",   // api.segment.io
        "segment.com",
        "segmentapis.com",   // the EU workspaces
        "mixpanel.com",
        "mxpnl.com",
        "amplitude.com",   // api2.amplitude.com is the ingest host
        "posthog.com",
        "heapanalytics.com",
        "fullstory.com",
        "lr-ingest.io",   // LogRocket
        "matomo.cloud",   // the hosted one; self-hosted is any host at all
        "clarity.ms",
        "browser-intake-datadoghq.com",
        "statsig.com",
        "statsigapi.net",
        "featuregates.org",
        "featureassets.org",
        "prodregistryv2.org",
        "assetsconfigcdn.org",
        "beyondwickedmapping.org",
    ]

    static let crashReportingHosts = [
        "sentry.io",   // covers the per-customer o123.ingest.sentry.io
        "bugsnag.com",
        "insighthub.smartbear.com",   // where BugSnag is moving
        "crashlytics.com",
        "crashlyticsreports-pa.googleapis.com",
        "firebaselogging.googleapis.com",
        "app-measurement.com",
        "appcenter.ms",
        "raygun.io",
        "raygun.com",
        "rollbar.com",
        "honeybadger.io",
    ]

    static let attributionHosts = [
        "appsflyer.com",
        "adjust.com",
        "branch.io",
        "kochava.com",
        "singular.net",
    ]

    /// Every one of these resolved when it was written down, which is more than can be said for the Apple
    /// blocklists in circulation — `metrics.apple.com` and `dzc-metrics.mzstatic.com` are in several of them and
    /// neither exists any more.
    static let appleTelemetryHosts = [
        "advertising.apple.com",
        "iad.apple.com",
        "iadsdk.apple.com",   // covers the ca./cf./cs./su./tr./ut. fronts
        "iadworkbench.apple.com",
        "api-adservices.apple.com",
        "searchads.apple.com",
        "securemetrics.apple.com",
        "supportmetrics.apple.com",
        "securemvt.apple.com",
        "metrics.icloud.com",
        "axm-telemetry.apple.com",
        "books-analytics-events.apple.com",
        "notes-analytics-events.apple.com",
        "weather-analytics-events.apple.com",
        "stocks-analytics-events.apple.com",
    ]
}

// MARK: Working hours

extension RuleTemplate {
    /// A window is the one schedule that comes back by itself, which makes it the only one worth writing as a
    /// policy rather than as a reaction. Everything here is a weekly shape.
    static let hours: [RuleTemplate] = [
        RuleTemplate(
            id: "hours.app-working-hours",
            title: "This app, only during working hours",
            summary: "The named app reaches nothing outside 09:00–18:00, Monday to Friday. For an agent, that is "
                + "the difference between an overnight run and an overnight run you find out about at nine.",
            category: .hours, needs: .app,
            caveat: "Two rules: one for the nights, one for the weekend. A single window can only say one of "
                + "those. Hours are local, and a Mac that sleeps through the end of a window finds it closed on "
                + "waking.",
            build: { subject in outsideWorkingHours(app: subject, label: "outside working hours") }),

        RuleTemplate(
            id: "hours.app-weekends-off",
            title: "This app, not at the weekend",
            summary: "Saturday and Sunday, all day. For a tool that has no reason to be running when you aren't.",
            category: .hours, needs: .app,
            caveat: nil,
            build: { subject in
                var rule = Rule(action: .block, app: subject.app, origin: .preset)
                rule.schedule = Rule.Schedule(kind: .window, days: [1, 7], start: 0, end: 24 * 60)
                rule.name = "\(subject.appName): not at the weekend"
                return [rule]
            }),

        RuleTemplate(
            id: "hours.destination-working-hours",
            title: "This destination, only outside working hours",
            summary: "Refuses one destination for everything on the Mac between 09:00 and 18:00 on weekdays, and "
                + "leaves it alone the rest of the time.",
            category: .hours, needs: .destination,
            caveat: "The window is when the block applies, not when the destination is allowed — the rule is "
                + "in force during the hours it names.",
            build: { subject in
                var rule = Rule(action: .block, app: subject.app, destination: subject.destination, origin: .preset)
                rule.schedule = Rule.Schedule(kind: .window, days: [2, 3, 4, 5, 6], start: 9 * 60, end: 18 * 60)
                rule.name = "\(subject.destination), during working hours"
                return [rule]
            }),
    ]

    /// Outside 09:00–18:00 Monday to Friday, said as the two windows it takes: every night, and all weekend.
    /// One window can't express it — a window is a run of hours on chosen days, and "not at work" is both.
    private static func outsideWorkingHours(app subject: Subject, label: String) -> [Rule] {
        var nights = Rule(action: .block, app: subject.app, origin: .preset)
        nights.schedule = Rule.Schedule(kind: .window, days: [], start: 18 * 60, end: 9 * 60)
        nights.name = "\(subject.appName): \(label) (nights)"

        var weekend = Rule(action: .block, app: subject.app, origin: .preset)
        weekend.schedule = Rule.Schedule(kind: .window, days: [1, 7], start: 0, end: 24 * 60)
        weekend.name = "\(subject.appName): \(label) (weekend)"

        return [nights, weekend]
    }
}

// MARK: One-off investigation

extension RuleTemplate {
    /// Something appeared in Live and you want it to stop while you find out what it was. These are the only
    /// templates that are saved without being shown first, and they are all rules that undo themselves.
    static let investigation: [RuleTemplate] = [
        RuleTemplate(
            id: "investigate.destination-for-an-hour",
            title: "Block this destination for an hour",
            summary: "Everything on the Mac, refused from reaching it, until an hour from now. Long enough to see "
                + "what breaks; short enough to forget about safely.",
            category: .investigation, needs: .destination,
            caveat: nil,
            appliesImmediately: true,
            build: { subject in
                var rule = Rule(action: .block, destination: subject.destination, origin: .preset)
                rule.schedule = .expiring(in: 3600)
                rule.name = "\(subject.destination), for an hour"
                return [rule]
            }),

        RuleTemplate(
            id: "investigate.destination-this-session",
            title: "Block this destination until Flowlight quits",
            summary: "The same, but measured against this run of Flowlight rather than the clock. Nothing is left "
                + "in force if it crashes.",
            category: .investigation, needs: .destination,
            caveat: nil,
            appliesImmediately: true,
            build: { subject in
                var rule = Rule(action: .block, destination: subject.destination, origin: .preset)
                rule.schedule = .thisSession(RuleStore.session)
                rule.name = "\(subject.destination), this session"
                return [rule]
            }),

        RuleTemplate(
            id: "investigate.app-and-destination-for-an-hour",
            title: "Block just this app from this destination, for an hour",
            summary: "Narrower than blocking the destination outright: everything else on the Mac keeps reaching "
                + "it, which is how you tell whether the app was the reason it looked wrong.",
            category: .investigation, needs: .both,
            caveat: nil,
            appliesImmediately: true,
            build: { subject in
                var rule = Rule(action: .block, app: subject.app, destination: subject.destination, origin: .preset)
                rule.schedule = .expiring(in: 3600)
                rule.name = "\(subject.appName) → \(subject.destination), for an hour"
                return [rule]
            }),

        RuleTemplate(
            id: "investigate.app-everywhere-this-session",
            title: "Block this app everywhere, until Flowlight quits",
            summary: "The whole app off the network for this run. The bluntest question there is, and it answers "
                + "itself as soon as something stops working.",
            category: .investigation, needs: .app,
            caveat: "An app named here also covers the tools it started, so blocking an agent blocks the `curl` "
                + "it ran.",
            appliesImmediately: true,
            build: { subject in
                var rule = Rule(action: .block, app: subject.app, origin: .preset)
                rule.schedule = .thisSession(RuleStore.session)
                rule.name = "\(subject.appName), this session"
                return [rule]
            }),
    ]
}

// MARK: Handing a template to the Rules screen

/// The one piece of state a context menu needs to pass to the Rules screen: which template was chosen, and what
/// the row already knew about it.
///
/// A shared object rather than an environment one because the menus that raise it live on four different screens
/// and the screen that answers it is always the same, so threading it through every view in between would buy
/// nothing. It holds one pending request at a time; a second click replaces the first.
@MainActor
final class RuleTemplateRequests: ObservableObject {
    static let shared = RuleTemplateRequests()

    struct Pending: Identifiable {
        let id = UUID()
        var template: RuleTemplate
        var subject: RuleTemplate.Subject
    }

    @Published var pending: Pending?

    func open(_ template: RuleTemplate, for subject: RuleTemplate.Subject) {
        pending = Pending(template: template, subject: subject)
    }
}
