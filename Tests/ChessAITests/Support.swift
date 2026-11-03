import Foundation
import ChessCore
import ChessEngine
@testable import ChessAI

/// A backend that records every request and answers through a closure. Never touches a real CLI.
final class FakeBackend: ModelBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [ModelRequest] = []
    private let handler: @Sendable (ModelRequest) throws -> [String: Any]

    init(_ handler: @escaping @Sendable (ModelRequest) throws -> [String: Any]) { self.handler = handler }

    var requests: [ModelRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var callCount: Int { requests.count }

    private func record(_ request: ModelRequest) { lock.lock(); _requests.append(request); lock.unlock() }

    func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply {
        record(request)
        return ModelReply(json: try handler(request), usage: ModelUsage(), seconds: 0)
    }
}

struct FakeFailure: Error {}

func makeRouter(_ backend: ModelBackend) -> ModelRouter {
    let routing = ModelRouting(
        strong: ModelSpec(backend: .claudeCLI, model: "strong"), cheap: ModelSpec(backend: .claudeCLI, model: "cheap"))
    return ModelRouter(routing: routing, backends: [.claudeCLI: backend])
}

func tempStore() -> (MemoryStore, URL) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chessai-tests-\(UUID().uuidString)")
    return (MemoryStore(root: url), url)
}

func singlePlayer(_ opponent: OpponentID, color: PieceColor = .white, persona: String = "kasia") -> MatchContext {
    try! MatchContext(mode: .singlePlayer, personaID: persona, opponent: opponent, personaColor: color)
}

func pvp(_ opponent: OpponentID, color: PieceColor = .white, persona: String = "kasia") -> MatchContext {
    try! MatchContext(mode: .pvp, personaID: persona, opponent: opponent, personaColor: color)
}

func note(
    _ id: String, _ category: NoteCategory = .strategy, statement: String? = nil, confidence: Double = 0.5,
    evidence: [String] = [], line: [String]? = nil, side: PieceColor? = nil
) -> Note {
    Note(id: id, category: category, statement: statement ?? "statement of \(id)", rationale: "because \(id)",
         line: line, side: side, confidence: confidence, evidence: evidence)
}

func startedEngine() async throws -> StockfishEngine {
    guard StockfishEngine.locate() != nil else { throw XCTSkipHelper.skip }
    let engine = try StockfishEngine()
    try await engine.start()
    return engine
}

import XCTest
enum XCTSkipHelper { static let skip = XCTSkip("stockfish not installed") }
