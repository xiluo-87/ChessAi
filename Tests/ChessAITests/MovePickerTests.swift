import XCTest
import ChessCore
import ChessEngine
@testable import ChessAI

final class MovePickerTests: XCTestCase {
    /// Candidate SANs from the prompt's numbered list.
    static func candidates(in prompt: String) -> [String] {
        guard let range = prompt.range(of: "Candidates") else { return [] }
        return prompt[range.upperBound...].split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0].hasSuffix("."), Int(parts[0].dropLast()) != nil else { return nil }
            return String(parts[1])
        }
    }

    func picker(
        _ backend: FakeBackend, engine: StockfishEngine, settings: PlaySettings, persona: PersonaProfile = MemoryStore.defaultPersona,
        dossier: OpponentDossier? = nil, context: MatchContext? = nil
    ) -> MovePicker {
        MovePicker(
            router: makeRouter(backend), engine: engine, settings: settings, persona: persona, dossier: dossier,
            context: context ?? singlePlayer(.human("alice")))
    }

    /// A rook endgame (phase .endgame, so the "equal developing moves" gate cannot fire) with several sound moves.
    static func endgame() -> Game { Game(start: Position(fen: "4k3/pppp4/8/8/8/8/PPPP4/R3K2R w - - 0 1")!) }

    func testPacedBudget() {
        XCTAssertEqual(MovePicker.pacedBudget(0, ply: 0), 0)
        XCTAssertEqual(MovePicker.pacedBudget(1, ply: 0), 1)
        XCTAssertEqual(MovePicker.pacedBudget(4, ply: 0), 1)
        XCTAssertEqual(MovePicker.pacedBudget(25, ply: 0), 7)
        XCTAssertEqual(MovePicker.pacedBudget(25, ply: 40), 16)
        XCTAssertEqual(MovePicker.pacedBudget(25, ply: 80), 25)
        XCTAssertEqual(MovePicker.pacedBudget(25, ply: 200), 25)
        var last = 0
        for ply in 0...100 {
            let value = MovePicker.pacedBudget(25, ply: ply)
            XCTAssertGreaterThanOrEqual(value, last)
            last = value
        }
    }

    func testPacingHoldsBackSecondCallAtSamePly() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { request in
            ["move": Self.candidates(in: request.prompt)[0], "reason": "r", "plan": "p"]
        }
        var settings = Self.wide
        settings.maxModelCalls = 4
        let p = picker(backend, engine: engine, settings: settings)
        let first = try await p.choose(in: Self.endgame())
        let second = try await p.choose(in: Self.endgame())
        XCTAssertEqual(first.source, .model)
        XCTAssertEqual(second.source, .engine)
        XCTAssertEqual(backend.callCount, 1)
    }

    static let wide = PlaySettings(engineDepth: 8, candidates: 4, marginCp: 300, obviousGapCp: 150, maxModelCalls: 25, thinkFromPly: 0)

    func testForcedMoveUsesNoModel() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { _ in ["move": "x", "reason": "r", "plan": "p"] }
        let game = Game(start: Position(fen: "4k3/8/8/8/8/8/5r2/4K2r w - - 0 1")!)
        XCTAssertEqual(game.current.legalMoves().count, 1)
        let decision = try await picker(backend, engine: engine, settings: Self.wide).choose(in: game)
        XCTAssertEqual(decision.source, .forced)
        XCTAssertEqual(game.current.san(for: decision.move), "Kxf2")
        XCTAssertEqual(backend.callCount, 0)
    }

    func testRepertoireGivesBookMoveWithoutModel() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        var persona = MemoryStore.defaultPersona
        persona.notes = [note("e4-open", .opening, confidence: 0.8, line: ["e4", "e5", "Nf3"], side: .white)]
        let backend = FakeBackend { _ in ["move": "x", "reason": "r", "plan": "p"] }
        let p = picker(backend, engine: engine, settings: Self.wide, persona: persona)

        var game = Game()
        var decision = try await p.choose(in: game)
        XCTAssertEqual(decision.source, .book)
        XCTAssertEqual(game.current.san(for: decision.move), "e4")

        XCTAssertTrue(game.play(decision.move))
        XCTAssertTrue(game.play(game.current.move(fromSAN: "e5")!))
        decision = try await p.choose(in: game)
        XCTAssertEqual(decision.source, .book)
        XCTAssertEqual(game.current.san(for: decision.move), "Nf3")
        XCTAssertEqual(backend.callCount, 0)

        // Deviation: the line no longer applies.
        var other = Game()
        XCTAssertTrue(other.play(other.current.move(fromSAN: "e4")!))
        XCTAssertTrue(other.play(other.current.move(fromSAN: "c5")!))
        let off = try await p.choose(in: other)
        XCTAssertNotEqual(off.source, .book)
    }

    func testOpeningBookMoveSkipsEngineAndModel() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { _ in ["move": "x", "reason": "r", "plan": "p"] }
        let book = try OpeningBook(text: "\(OpeningBook.key(.start)) ; d2d4 1\n")
        let p = MovePicker(
            router: makeRouter(backend), engine: engine, settings: Self.wide, persona: MemoryStore.defaultPersona,
            dossier: nil, context: singlePlayer(.human("alice")), book: book)
        let decision = try await p.choose(in: Game())
        XCTAssertEqual(decision.source, .book)
        XCTAssertEqual(decision.move.uci, "d2d4")
        XCTAssertEqual(decision.reason, "opening book")
        XCTAssertEqual(backend.callCount, 0)
    }

    func testRepertoireForOtherSideIsIgnored() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        var persona = MemoryStore.defaultPersona
        persona.notes = [note("e4-open", .opening, line: ["e4", "e5"], side: .white)]
        let backend = FakeBackend { _ in ["move": "x", "reason": "r", "plan": "p"] }
        let settings = PlaySettings(engineDepth: 8, maxModelCalls: 0, thinkFromPly: 0)
        let p = picker(backend, engine: engine, settings: settings, persona: persona, context: singlePlayer(.human("a"), color: .black))
        var game = Game()
        XCTAssertTrue(game.play(game.current.move(fromSAN: "d4")!))
        let d = try await p.choose(in: game)
        XCTAssertNotEqual(d.source, .book)
    }

    func testModelAnswerPlayedAsModelSource() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { request in
            let list = Self.candidates(in: request.prompt)
            guard list.count >= 2 else { throw FakeFailure() }
            return ["move": list[1], "reason": "style", "plan": "develop"]
        }
        let game = Self.endgame()
        let decision = try await picker(backend, engine: engine, settings: Self.wide).choose(in: game)
        XCTAssertEqual(backend.callCount, 1)
        let list = Self.candidates(in: backend.requests[0].prompt)
        XCTAssertGreaterThanOrEqual(list.count, 2)
        XCTAssertEqual(decision.source, .model)
        XCTAssertEqual(game.current.san(for: decision.move), list[1])
        XCTAssertEqual(decision.reason, "style")
    }

    func testEngineTopIsNamedOnlyWhenTheModelChoseAnother() throws {
        let top = try XCTUnwrap(Move(uci: "e2e4")), other = try XCTUnwrap(Move(uci: "d2d4"))
        let score = EngineScore(centipawns: 20, mate: nil)
        let candidates = [
            Candidate(move: top, san: "e4", score: score, line: []),
            Candidate(move: other, san: "d4", score: score, line: []),
        ]
        func decision(_ move: Move, _ source: MoveSource) -> MoveDecision {
            MoveDecision(move: move, source: source, reason: nil, candidates: candidates, evalWhite: nil)
        }
        XCTAssertEqual(decision(other, .model).engineTop, "e4")
        XCTAssertNil(decision(top, .model).engineTop)
        XCTAssertNil(decision(top, .engine).engineTop)
    }

    func testNonCandidateAnswerFallsBackToEngine() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let bad = FakeBackend { _ in ["move": "Qh5xx", "reason": "r", "plan": "p"] }
        let decision = try await picker(bad, engine: engine, settings: Self.wide).choose(in: Self.endgame())
        XCTAssertEqual(bad.callCount, 1)
        XCTAssertEqual(decision.source, .engine)
        XCTAssertEqual(decision.reason?.contains("not a candidate"), true)
    }

    func testZeroModelBudgetNeverCallsModel() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { _ in ["move": "e4", "reason": "r", "plan": "p"] }
        var settings = Self.wide
        settings.maxModelCalls = 0
        let decision = try await picker(backend, engine: engine, settings: settings).choose(in: Self.endgame())
        XCTAssertEqual(decision.source, .engine)
        XCTAssertEqual(backend.callCount, 0)
    }

    func testBudgetCapsCallsAcrossMoves() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { request in
            ["move": Self.candidates(in: request.prompt)[0], "reason": "r", "plan": "p"]
        }
        var settings = Self.wide
        settings.maxModelCalls = 1
        let p = picker(backend, engine: engine, settings: settings)
        _ = try await p.choose(in: Self.endgame())
        _ = try await p.choose(in: Self.endgame())
        XCTAssertEqual(backend.callCount, 1)
        let calls = await p.modelCalls
        XCTAssertEqual(calls, 1)
    }

    func testThrowingBackendFallsBackToEngine() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { _ in throw FakeFailure() }
        let decision = try await picker(backend, engine: engine, settings: Self.wide).choose(in: Self.endgame())
        XCTAssertEqual(backend.callCount, 1)
        XCTAssertEqual(decision.source, .engine)
        XCTAssertFalse(decision.candidates.isEmpty)
    }

    func testThinkFromPlyDefersModel() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let backend = FakeBackend { _ in throw FakeFailure() }
        var settings = Self.wide
        settings.thinkFromPly = 4
        let decision = try await picker(backend, engine: engine, settings: settings).choose(in: Self.endgame())
        XCTAssertEqual(decision.source, .engine)
        XCTAssertEqual(backend.callCount, 0)
    }

    // MARK: Privacy through the prompt

    func testPvPPromptNeverContainsHumanNotes() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        let secret = "ALICE_PRIVATE_NOTE_STATEMENT"
        var human = OpponentDossier(opponent: .human("alice"))
        human.notes = [note("s", .tendency, statement: secret)]
        let backend = FakeBackend { request in
            ["move": Self.candidates(in: request.prompt)[0], "reason": "r", "plan": "p"]
        }
        let p = picker(backend, engine: engine, settings: Self.wide, dossier: human, context: pvp(.model("gpt")))
        let decision = try await p.choose(in: Self.endgame())
        XCTAssertEqual(decision.source, .model)
        XCTAssertEqual(backend.callCount, 1)
        let request = backend.requests[0]
        XCTAssertFalse(request.system.contains(secret))
        XCTAssertFalse(request.prompt.contains(secret))
        XCTAssertFalse(request.system.contains("alice"))
    }

    func testOwnModelDossierReachesPvPPromptButOtherModelsDoNot() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        var own = OpponentDossier(opponent: .model("gpt"))
        own.notes = [note("own", .tendency, statement: "GPT_NOTE_VISIBLE")]
        var other = OpponentDossier(opponent: .model("claude"))
        other.notes = [note("oth", .tendency, statement: "CLAUDE_NOTE_HIDDEN")]
        let backend = FakeBackend { request in
            ["move": Self.candidates(in: request.prompt)[0], "reason": "r", "plan": "p"]
        }
        _ = try await picker(backend, engine: engine, settings: Self.wide, dossier: own, context: pvp(.model("gpt"))).choose(in: Self.endgame())
        XCTAssertTrue(backend.requests[0].system.contains("GPT_NOTE_VISIBLE"))
        _ = try await picker(backend, engine: engine, settings: Self.wide, dossier: other, context: pvp(.model("gpt"))).choose(in: Self.endgame())
        XCTAssertFalse(backend.requests[1].system.contains("CLAUDE_NOTE_HIDDEN"))
    }

    func testSinglePlayerPromptContainsHumanNotes() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        var human = OpponentDossier(opponent: .human("alice"))
        human.notes = [note("s", .tendency, statement: "ALICE_NOTE_VISIBLE")]
        let backend = FakeBackend { request in
            ["move": Self.candidates(in: request.prompt)[0], "reason": "r", "plan": "p"]
        }
        _ = try await picker(backend, engine: engine, settings: Self.wide, dossier: human, context: singlePlayer(.human("alice"))).choose(in: Self.endgame())
        XCTAssertTrue(backend.requests[0].system.contains("ALICE_NOTE_VISIBLE"))
    }
}
