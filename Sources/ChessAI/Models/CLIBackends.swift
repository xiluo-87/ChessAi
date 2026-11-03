import Foundation

// The three CLI adapters. Flags and environment rules follow the pipeline's adapters in
// ~/Repositories/OpenCode/pipeline/src/backends (claude/args.ts, codex/args.ts, opencode/client.ts), trimmed to what a
// chess call needs: one stateless prompt, no tools, no files, no user configuration, a JSON answer.

/// `claude -p` with no tools and a replaced system prompt: the smallest prompt Claude Code sends (about 1.1k tokens),
/// on the plan login.
public struct ClaudeCLIBackend: ModelBackend {
    /// Inherited names that would outrank the plan login or redirect requests (claudeEnvironment in args.ts).
    static func dropped(_ name: String) -> Bool {
        name != "CLAUDE_CODE_OAUTH_TOKEN"
            && (name.hasPrefix("ANTHROPIC_") || name == "CLAUDECODE" || name.hasPrefix("CLAUDE_"))
    }

    static let isolation = [
        "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_AUTOUPDATER": "1",
    ]

    public init() {}

    static func arguments(_ request: ModelRequest, model: ModelSpec) -> [String] {
        var args = [
            "-p", "--output-format", "json",
            "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
            "--tools", "",
            "--system-prompt", request.system,
            "--json-schema", request.schemaJSON,
            "--model", model.model,
        ]
        if let effort = model.effort { args += ["--effort", effort] }
        return args
    }

    public func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply {
        guard let binary = CLIRunner.locate("claude") else { throw ModelError.notInstalled("claude") }
        let out = try await CLIRunner.run(
            binary, Self.arguments(request, model: model), stdin: request.prompt,
            environment: CLIRunner.environment(dropping: Self.dropped, extra: Self.isolation),
            directory: FileManager.default.temporaryDirectory, timeout: request.timeout)
        guard let result = (try? JSONSerialization.jsonObject(with: Data(out.stdout.utf8))) as? [String: Any] else {
            throw ModelError.failed("claude exited \(out.status): \(out.stderr.tail()) \(out.stdout.tail())")
        }
        if (result["is_error"] as? Bool) == true {
            throw ModelError.failed("claude: \(result["result"] as? String ?? out.stderr.tail())")
        }
        let json = result["structured_output"] as? [String: Any]
            ?? (result["result"] as? String).flatMap(ModelBackends.firstJSONObject(in:))
        guard let json else { throw ModelError.badOutput("no structured_output in claude result") }

        var usage = ModelUsage()
        if let u = result["usage"] as? [String: Any] {
            usage.inputTokens = (u["input_tokens"] as? Int ?? 0) + (u["cache_creation_input_tokens"] as? Int ?? 0)
            usage.cachedTokens = u["cache_read_input_tokens"] as? Int ?? 0
            usage.outputTokens = u["output_tokens"] as? Int ?? 0
        }
        usage.costUSD = result["total_cost_usd"] as? Double
        return ModelReply(json: json, usage: usage, seconds: out.seconds)
    }
}

/// `codex exec` read-only, ephemeral, ignoring user config and rules, with the schema as `--output-schema`.
public struct CodexCLIBackend: ModelBackend {
    /// Each of these wins over the saved ChatGPT login (droppedEnvironment in codex/args.ts).
    static let droppedNames: Set<String> = ["CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_API_KEY"]

    public init() {}

    static func arguments(schemaFile: String, directory: String, model: ModelSpec) -> [String] {
        var args = [
            "exec", "--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
            "--output-schema", schemaFile, "-C", directory, "-m", model.model,
        ]
        if let effort = model.effort { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        args += [
            "-c", "approval_policy=\"never\"",
            "-c", "sandbox_mode=\"read-only\"",
            "-c", "project_doc_max_bytes=0",
            "-c", "web_search=\"disabled\"",
            "-c", "agents.enabled=false",
            "-c", "features.multi_agent=false",
            "-c", "features.apps=false",
            "-c", "features.plugins=false",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-",
        ]
        return args
    }

    public func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply {
        guard let binary = CLIRunner.locate("codex") else { throw ModelError.notInstalled("codex") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chessai-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let schemaFile = folder.appendingPathComponent("schema.json")
        try request.schemaJSON.write(to: schemaFile, atomically: true, encoding: .utf8)

        // codex exec has no system prompt flag: the system text leads the prompt.
        let out = try await CLIRunner.run(
            binary, Self.arguments(schemaFile: schemaFile.path, directory: folder.path, model: model),
            stdin: request.system + "\n\n---\n\n" + request.prompt,
            environment: CLIRunner.environment(dropping: { Self.droppedNames.contains($0) }),
            directory: folder, timeout: request.timeout)

        var lastMessage: String?
        var usage = ModelUsage()
        var failure: String?
        for line in out.stdout.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    lastMessage = item["text"] as? String
                }
            case "turn.completed":
                if let u = event["usage"] as? [String: Any] {
                    usage.cachedTokens = u["cached_input_tokens"] as? Int ?? 0
                    usage.inputTokens = (u["input_tokens"] as? Int ?? 0) - usage.cachedTokens
                    usage.outputTokens = u["output_tokens"] as? Int ?? 0
                }
            case "turn.failed", "error":
                failure = ((event["error"] as? [String: Any])?["message"] as? String) ?? event["message"] as? String
            default: break
            }
        }
        if let failure { throw ModelError.failed("codex: \(failure)") }
        guard let text = lastMessage, let json = ModelBackends.firstJSONObject(in: text) else {
            throw ModelError.badOutput("codex exited \(out.status) without a JSON answer: \(out.stderr.tail())")
        }
        return ModelReply(json: json, usage: usage, seconds: out.seconds)
    }
}

/// `opencode run --format json`: any provider/model OpenCode serves. It cannot enforce a schema, so the schema goes
/// into the prompt and the first JSON object of the answer is taken.
public struct OpenCodeBackend: ModelBackend {
    public init() {}

    public func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply {
        guard let binary = CLIRunner.locate("opencode") else { throw ModelError.notInstalled("opencode") }
        let modelRef = model.effort.map { "\(model.model)#\($0)" } ?? model.model
        let message = """
            \(request.system)

            ---

            \(request.prompt)

            Answer with one JSON object only, matching this JSON schema:
            \(request.schemaJSON)
            """
        let out = try await CLIRunner.run(
            binary, ["run", "--format", "json", "-m", modelRef, "--title", "chessai", message], stdin: "",
            environment: CLIRunner.environment(dropping: { _ in false }),
            directory: FileManager.default.temporaryDirectory, timeout: request.timeout)

        var text = ""
        var usage = ModelUsage()
        for line in out.stdout.split(separator: "\n") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let part = event["part"] as? [String: Any] ?? event
            if part["type"] as? String == "text", let t = part["text"] as? String { text += t }
            if let tokens = part["tokens"] as? [String: Any] {
                usage.inputTokens += tokens["input"] as? Int ?? 0
                usage.outputTokens += tokens["output"] as? Int ?? 0
                usage.cachedTokens += (tokens["cache"] as? [String: Any])?["read"] as? Int ?? 0
            }
            if let cost = part["cost"] as? Double { usage.costUSD = (usage.costUSD ?? 0) + cost }
        }
        guard let json = ModelBackends.firstJSONObject(in: text.isEmpty ? out.stdout : text) else {
            throw ModelError.badOutput("opencode exited \(out.status) without a JSON answer: \(out.stderr.tail())")
        }
        return ModelReply(json: json, usage: usage, seconds: out.seconds)
    }
}
