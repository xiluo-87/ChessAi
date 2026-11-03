import Foundation

/// The models the picker offers per backend. Claude and Codex have fixed lists (their CLIs print none); OpenCode lists
/// what its server serves through `opencode models`. Any other id can still be typed in.
public enum ModelCatalog {
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// Rough relative price, for the picker's hint: 1 cheapest.
        public var priceTier: Int
    }

    public static let claude: [Entry] = [
        Entry(id: "haiku", name: "Haiku (latest)", priceTier: 1),
        Entry(id: "sonnet", name: "Sonnet (latest)", priceTier: 2),
        Entry(id: "opus", name: "Opus (latest)", priceTier: 3),
        Entry(id: "fable", name: "Fable (latest)", priceTier: 4),
        Entry(id: "claude-haiku-5-5", name: "Haiku 5.5", priceTier: 1),
        Entry(id: "claude-sonnet-5-5", name: "Sonnet 5.5", priceTier: 2),
        Entry(id: "claude-opus-5-5", name: "Opus 5.5", priceTier: 3),
        Entry(id: "claude-fable-5-1", name: "Fable 5.1", priceTier: 4),
    ]

    public static let codex: [Entry] = [
        Entry(id: "gpt-6.1-sol", name: "GPT-6.1 Sol", priceTier: 3),
        Entry(id: "gpt-6.1-sol-mini", name: "GPT-6.1 Sol mini", priceTier: 1),
    ]

    public static let efforts: [BackendKind: [String]] = [
        .claudeCLI: ["low", "medium", "high", "xhigh", "max"],
        .codexCLI: ["low", "medium", "high", "xhigh"],
        .openCode: ["low", "medium", "high"],
    ]

    public static func installed(_ backend: BackendKind) -> Bool {
        CLIRunner.locate(backend.command) != nil
    }

    public static func models(for backend: BackendKind) async -> [Entry] {
        switch backend {
        case .claudeCLI: return claude
        case .codexCLI: return codex
        case .openCode:
            guard let binary = CLIRunner.locate("opencode"),
                  let out = try? await CLIRunner.run(
                    binary, ["models"], stdin: "", environment: CLIRunner.environment(dropping: { _ in false }), timeout: 30),
                  out.status == 0 else { return [] }
            return out.stdout.split(separator: "\n").map(String.init).filter { $0.contains("/") }
                .map { Entry(id: $0, name: $0, priceTier: 0) }
        }
    }
}

extension BackendKind {
    public var command: String {
        switch self {
        case .claudeCLI: "claude"
        case .codexCLI: "codex"
        case .openCode: "opencode"
        }
    }

    public var title: String {
        switch self {
        case .claudeCLI: "Claude Code (plan login)"
        case .codexCLI: "Codex (ChatGPT login)"
        case .openCode: "OpenCode (API keys / local)"
        }
    }
}
