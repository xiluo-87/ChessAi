import Foundation

/// The CLIs a model call can run on. Each runs one stateless, tool-less prompt with a JSON schema for its answer.
public enum BackendKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `claude -p`: anthropic models on the plan login (cheapest: no API spend).
    case claudeCLI = "claude-cli"
    /// `codex exec`: openai models on the ChatGPT login.
    case codexCLI = "codex-cli"
    /// `opencode run`: any provider OpenCode knows (API keys, local models).
    case openCode = "opencode"

    public var id: String { rawValue }
}

/// One model choice: the backend, the model id as that CLI takes it, and an optional reasoning effort.
public struct ModelSpec: Codable, Sendable, Hashable {
    public var backend: BackendKind
    public var model: String
    public var effort: String?

    public init(backend: BackendKind, model: String, effort: String? = nil) {
        self.backend = backend
        self.model = model
        self.effort = effort
    }

    public var label: String { effort.map { "\(model)#\($0)" } ?? model }
}

/// One stateless request: a system prompt (kept identical across a game so providers can cache it), the user text,
/// and the JSON schema the answer must follow.
public struct ModelRequest: @unchecked Sendable {
    public var system: String
    public var prompt: String
    public var schema: [String: Any]
    /// Wall clock for the whole call.
    public var timeout: TimeInterval

    public init(system: String, prompt: String, schema: [String: Any], timeout: TimeInterval = 120) {
        self.system = system
        self.prompt = prompt
        self.schema = schema
        self.timeout = timeout
    }

    var schemaJSON: String {
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ModelUsage: Codable, Sendable, Hashable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cachedTokens = 0
    /// What the provider reports; nil when the backend does not report a price.
    public var costUSD: Double?

    public init() {}

    public static func + (a: ModelUsage, b: ModelUsage) -> ModelUsage {
        var sum = ModelUsage()
        sum.inputTokens = a.inputTokens + b.inputTokens
        sum.outputTokens = a.outputTokens + b.outputTokens
        sum.cachedTokens = a.cachedTokens + b.cachedTokens
        if a.costUSD != nil || b.costUSD != nil { sum.costUSD = (a.costUSD ?? 0) + (b.costUSD ?? 0) }
        return sum
    }
}

public struct ModelReply: @unchecked Sendable {
    /// The structured answer, already decoded from JSON.
    public var json: [String: Any]
    public var usage: ModelUsage
    public var seconds: Double
}

public enum ModelError: Error, LocalizedError {
    case notInstalled(String)
    case failed(String)
    case timeout(TimeInterval)
    case badOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let cli): "\(cli) is not installed or not on PATH"
        case .failed(let detail): "model call failed: \(detail)"
        case .timeout(let seconds): "model call gave no answer within \(Int(seconds)) s"
        case .badOutput(let detail): "model answer could not be read: \(detail)"
        }
    }
}

public protocol ModelBackend: Sendable {
    func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply
}

public enum ModelBackends {
    public static func make(_ kind: BackendKind) -> ModelBackend {
        switch kind {
        case .claudeCLI: ClaudeCLIBackend()
        case .codexCLI: CodexCLIBackend()
        case .openCode: OpenCodeBackend()
        }
    }

    /// Pulls the first JSON object out of free text (for backends that cannot enforce a schema).
    static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }
}
