import Foundation

/// An AI agent or assistant Flowlight recognizes by name.
struct KnownAgent: Sendable, Equatable {
    var name: String
    var vendor: String
    var bundleIDs: Set<String> = []
    var processNames: Set<String> = []
}

/// Recognizes AI agents and LLM API traffic.
///
/// An app counts as an agent when it is a known agent, or when it talks to an LLM API provider
/// (auto-discovered, e.g. a Python or Node script calling api.openai.com). Browsers are excluded
/// from auto-discovery: a person chatting on chatgpt.com is not an autonomous agent.
enum AgentCatalog {
    static let agents: [KnownAgent] = [
        KnownAgent(name: "Claude", vendor: "Anthropic", bundleIDs: ["com.anthropic.claudefordesktop"]),
        KnownAgent(name: "Claude Code", vendor: "Anthropic", processNames: ["claude", "claude-code"]),
        KnownAgent(name: "ChatGPT", vendor: "OpenAI", bundleIDs: ["com.openai.chat"]),
        KnownAgent(name: "Codex", vendor: "OpenAI", processNames: ["codex"]),
        KnownAgent(name: "Cursor", vendor: "Anysphere", bundleIDs: ["com.todesktop.230313mzl4w4u92"], processNames: ["cursor", "cursor-agent"]),
        KnownAgent(name: "Windsurf", vendor: "Codeium", bundleIDs: ["com.exafunction.windsurf"], processNames: ["windsurf"]),
        KnownAgent(name: "Zed", vendor: "Zed Industries", bundleIDs: ["dev.zed.Zed"]),
        KnownAgent(name: "GitHub Copilot", vendor: "GitHub", processNames: ["copilot", "copilot-language-server"]),
        KnownAgent(name: "Gemini CLI", vendor: "Google", processNames: ["gemini"]),
        KnownAgent(name: "Aider", vendor: "Aider", processNames: ["aider"]),
        KnownAgent(name: "Goose", vendor: "Block", processNames: ["goose"]),
        KnownAgent(name: "OpenCode", vendor: "SST", processNames: ["opencode"]),
        KnownAgent(name: "Ollama", vendor: "Ollama", bundleIDs: ["com.electron.ollama"], processNames: ["ollama"]),
        KnownAgent(name: "LM Studio", vendor: "Element Labs", bundleIDs: ["ai.elementlabs.lmstudio"]),
        KnownAgent(name: "Perplexity", vendor: "Perplexity", bundleIDs: ["ai.perplexity.mac"]),
    ]

    /// Hostname suffix → LLM API provider.
    static let providers: [(suffix: String, name: String)] = [
        ("anthropic.com", "Anthropic"), ("claude.ai", "Anthropic"), ("claude.com", "Anthropic"),
        ("openai.com", "OpenAI"), ("chatgpt.com", "OpenAI"), ("oaiusercontent.com", "OpenAI"), ("openai.azure.com", "Azure OpenAI"),
        ("generativelanguage.googleapis.com", "Google Gemini"), ("aiplatform.googleapis.com", "Google Vertex AI"),
        ("gemini.google.com", "Google Gemini"), ("mistral.ai", "Mistral"), ("cohere.ai", "Cohere"), ("cohere.com", "Cohere"),
        ("groq.com", "Groq"), ("together.xyz", "Together AI"), ("together.ai", "Together AI"), ("deepseek.com", "DeepSeek"),
        ("openrouter.ai", "OpenRouter"), ("perplexity.ai", "Perplexity"), ("x.ai", "xAI"), ("fireworks.ai", "Fireworks AI"),
        ("replicate.com", "Replicate"), ("huggingface.co", "Hugging Face"), ("githubcopilot.com", "GitHub Copilot"),
        ("copilot-proxy.githubusercontent.com", "GitHub Copilot"), ("cursor.sh", "Cursor"), ("cursor.com", "Cursor"),
        ("codeium.com", "Codeium"), ("windsurf.com", "Codeium"), ("ollama.com", "Ollama"),
    ]

    /// Network owners (AS names) that only serve AI APIs, for traffic seen without a hostname.
    static let providerOwners: [(fragment: String, name: String)] = [("Anthropic", "Anthropic"), ("OpenAI", "OpenAI")]

    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS",
    ]

    static func knownAgent(bundleID: String, appName: String) -> KnownAgent? {
        let name = appName.lowercased()
        return agents.first { $0.bundleIDs.contains(bundleID) || $0.processNames.contains(name) || $0.processNames.contains(bundleID.lowercased()) }
    }

    /// The LLM provider behind a destination, if any.
    static func provider(domain: String, owner: String = "") -> String? {
        let host = domain.lowercased()
        if !host.isEmpty {
            if host.hasPrefix("bedrock-runtime.") || host.hasPrefix("bedrock.") { return "AWS Bedrock" }
            for entry in providers where host == entry.suffix || host.hasSuffix("." + entry.suffix) { return entry.name }
            return nil
        }
        return providerOwners.first { owner.localizedCaseInsensitiveContains($0.fragment) }?.name
    }

    static func isBrowser(_ bundleID: String) -> Bool { browsers.contains(bundleID) }
}
