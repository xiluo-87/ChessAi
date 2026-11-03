import XCTest
@testable import ChessAI

final class CLIBackendTests: XCTestCase {
    let request = ModelRequest(system: "SYSTEM TEXT", prompt: "p", schema: ["type": "object"])

    func value(after flag: String, in args: [String]) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    func testClaudeArguments() {
        let args = ClaudeCLIBackend.arguments(request, model: ModelSpec(backend: .claudeCLI, model: "opus", effort: "low"))
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--tools", in: args), "")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertTrue(args.contains("--safe-mode"))
        XCTAssertEqual(value(after: "--system-prompt", in: args), "SYSTEM TEXT")
        XCTAssertEqual(value(after: "--json-schema", in: args), request.schemaJSON)
        XCTAssertEqual(value(after: "--model", in: args), "opus")
        XCTAssertEqual(value(after: "--effort", in: args), "low")
        // The user prompt goes through stdin, never argv.
        XCTAssertFalse(args.contains("p"))
    }

    func testClaudeWithoutEffortOmitsFlag() {
        let args = ClaudeCLIBackend.arguments(request, model: ModelSpec(backend: .claudeCLI, model: "haiku"))
        XCTAssertFalse(args.contains("--effort"))
    }

    func testClaudeDroppedEnvironment() {
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_SSE_PORT"] {
            XCTAssertTrue(ClaudeCLIBackend.dropped(name), name)
        }
        for name in ["CLAUDE_CODE_OAUTH_TOKEN", "PATH", "HOME", "OPENAI_API_KEY"] {
            XCTAssertFalse(ClaudeCLIBackend.dropped(name), name)
        }
    }

    func testEnvironmentFilter() {
        let env = CLIRunner.environment(dropping: ClaudeCLIBackend.dropped, extra: ClaudeCLIBackend.isolation)
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNotNil(env["PATH"])
        XCTAssertEqual(env["DISABLE_AUTOUPDATER"], "1")
    }

    func testCodexArguments() {
        let args = CodexCLIBackend.arguments(schemaFile: "/tmp/s.json", directory: "/tmp/d", model: ModelSpec(backend: .codexCLI, model: "gpt-5", effort: "high"))
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("sandbox_mode=\"read-only\""))
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertEqual(args.last, "-")
        XCTAssertEqual(value(after: "--output-schema", in: args), "/tmp/s.json")
        XCTAssertEqual(value(after: "-C", in: args), "/tmp/d")
        XCTAssertEqual(value(after: "-m", in: args), "gpt-5")
        XCTAssertTrue(args.contains("model_reasoning_effort=\"high\""))
        XCTAssertTrue(args.contains("approval_policy=\"never\""))
    }

    func testCodexDroppedKeys() {
        XCTAssertTrue(CodexCLIBackend.droppedNames.isSuperset(of: ["OPENAI_API_KEY", "CODEX_API_KEY"]))
    }

    func testFirstJSONObject() {
        XCTAssertEqual(ModelBackends.firstJSONObject(in: "noise {\"a\": 1} tail")?["a"] as? Int, 1)
        XCTAssertNil(ModelBackends.firstJSONObject(in: "no json"))
    }

    func testRouterFallsBackAndLogsLedger() async throws {
        let failing = FakeBackend { _ in throw FakeFailure() }
        let working = FakeBackend { _ in ["ok": true] }
        let routing = ModelRouting(
            strong: ModelSpec(backend: .claudeCLI, model: "a"), cheap: ModelSpec(backend: .claudeCLI, model: "b"),
            fallbacks: [ModelSpec(backend: .codexCLI, model: "c")])
        let router = ModelRouter(routing: routing, backends: [.claudeCLI: failing, .codexCLI: working])
        let reply = try await router.call(request, tier: .strong, purpose: "t")
        XCTAssertEqual(reply.json["ok"] as? Bool, true)
        XCTAssertEqual(failing.callCount, 1)
        let records = await router.records()
        XCTAssertEqual(records.map(\.model), ["c"])
    }
}
