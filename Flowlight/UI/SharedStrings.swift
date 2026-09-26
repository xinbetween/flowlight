import Foundation

/// Words that belong to types in `Shared/`, translated where they are shown rather than where they are defined.
///
/// `Shared/` is compiled into the Network Extension as well as the app, and `L()` is the app's — the extension
/// has no catalog and nothing to show a string on. Two of these are also stored rather than merely displayed: a
/// guardrail's `name` and a rule's go into the database, so they have to stay English in the data and become the
/// reader's language only on the way to the screen. Translating at the display site is what keeps both true.
///
/// The English is repeated here as literals on purpose. `L(preset.name)` would find the translation at runtime
/// but `scripts/i18n_extract.py` reads keys out of the source, so a key that is only ever a variable never
/// reaches the catalog and never gets translated. Spelling them out is what puts them in front of a translator.

extension Guardrail {
    /// `title`, in the reader's language. The parts that name things the user typed — an agent, a server, a
    /// tool, a resource — stay exactly as they were typed.
    var localizedTitle: String {
        if !name.isEmpty { return name }
        let who = agent.isEmpty ? L("Any agent") : agent
        if !resource.isEmpty { return L("%@: no %@", who, resource) }
        let what = tool.isEmpty ? L("everything from %@", server)
                                : (server.isEmpty ? tool : "\(server) › \(tool)")
        return L("%@: no %@", who, what)
    }
}

extension Guardrail.Preset {
    var localizedName: String {
        switch name {
        case "No shell": return L("No shell")
        case "No writes": return L("No writes")
        case "Read-only": return L("Read-only")
        default: return name
        }
    }

    var localizedDetail: String {
        switch detail {
        case "The agent keeps its other tools, but can't run commands.":
            return L("The agent keeps its other tools, but can't run commands.")
        case "It can read and search, but not change anything.":
            return L("It can read and search, but not change anything.")
        case "Everything but reading and searching, refused.":
            return L("Everything but reading and searching, refused.")
        default: return detail
        }
    }
}

extension AgentPolicy.Preset {
    /// Most allowlist presets are proper nouns — GitHub, npm, PyPI, Homebrew, Docker Hub, Apple — and a proper
    /// noun is the same word in every language. Only these two say something.
    var localizedName: String {
        switch name {
        case "Rust crates": return L("Rust crates")
        case "Go modules": return L("Go modules")
        default: return name
        }
    }
}

extension NetworkChannel {
    /// The "Way out" picker's options and their explanations. Defined in `Shared/` because the capture engines
    /// classify by channel; shown only here.
    var localizedTitle: String {
        switch self {
        case .ip: return L("Network")
        case .peerToPeer: return L("Peer-to-peer Wi-Fi")
        case .loopback: return L("This Mac")
        case .tunnel: return L("Tunnel")
        }
    }

    var localizedDetail: String {
        switch self {
        case .ip: return L("Out through Wi-Fi or Ethernet.")
        case .peerToPeer:
            return L("Straight to a device nearby over AWDL — AirDrop, Handoff, AirPlay, Sidecar, Universal Control.")
        case .loopback: return L("Between processes on this Mac. It never touched a network.")
        case .tunnel: return L("Through a VPN or another tunnel; where it went after that isn't visible here.")
        }
    }
}

extension ProtocolCategory {
    /// The thirteen family names, as the alerts and the protocol tables show them. `title` itself stays English:
    /// `Shared/Classification` is compiled into the Network Extension, which has no catalog.
    var localizedTitle: String {
        switch self {
        case .web: return L("Web")
        case .mail: return L("Email")
        case .fileTransfer: return L("File transfer")
        case .remoteAccess: return L("Remote access")
        case .nameResolution: return L("Name resolution")
        case .tunnel: return L("VPN, proxy & tunnels")
        case .database: return L("Databases & caches")
        case .messaging: return L("Messaging & queues")
        case .media: return L("Voice, video & streaming")
        case .push: return L("Push notifications")
        case .networkServices: return L("Network services")
        case .peerToPeer: return L("Peer-to-peer")
        case .developer: return L("Developer services")
        case .other: return L("Other")
        }
    }
}
