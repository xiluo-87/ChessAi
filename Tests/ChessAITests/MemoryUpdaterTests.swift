import XCTest
import ChessCore
@testable import ChessAI

final class MemoryMergeTests: XCTestCase {
    func item(_ id: String, category: String = "strategy", line: [String]? = nil, seen: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
        var d: [String: Any] = [
            "id": id, "category": category, "statement": "st \(id)", "rationale": "why \(id)", "confidence": 0.6, "seenThisGame": seen,
        ]
        if let line { d["line"] = line }
        return d.merging(extra) { _, n in n }
    }

    func testLegalPrefixCutsAtIllegalMove() {
        XCTAssertEqual(MemoryUpdater.legalPrefix(["e4", "e5", "Qxh7", "Nf3"]), ["e4", "e5"])
        XCTAssertEqual(MemoryUpdater.legalPrefix(["Ke2"]), [])
        XCTAssertEqual(MemoryUpdater.legalPrefix([]), [])
        XCTAssertEqual(MemoryUpdater.legalPrefix(["e4", "e5", "Nf3", "Nc6"]), ["e4", "e5", "Nf3", "Nc6"])
    }

    func testLegalPrefixNormalizesSAN() {
        XCTAssertEqual(MemoryUpdater.legalPrefix(["e4", "e5", "Nf3+", "Nc6!"]).prefix(3), ["e4", "e5", "Nf3"])
        // Check marks are added by the engine's own spelling.
        let line = MemoryUpdater.legalPrefix(["e4", "f5", "Qh5"])
        XCTAssertEqual(line.last, "Qh5+")
    }

    func testIllegalOpeningLineIsCut() {
        let out = MemoryUpdater.merge(
            [item("o", category: "opening", line: ["e4", "e5", "Qxh7", "Nf3"], extra: ["side": "white"])],
            into: [], game: "g1", budget: .persona)
        XCTAssertEqual(out.first?.line, ["e4", "e5"])
        XCTAssertEqual(out.first?.side, .white)
    }

    func testFullyIllegalLineBecomesNil() {
        let out = MemoryUpdater.merge([item("o", category: "opening", line: ["Ke2"])], into: [], game: "g", budget: .persona)
        XCTAssertNil(out.first?.line)
    }

    func testLineDroppedForNonOpeningCategory() {
        let out = MemoryUpdater.merge([item("s", category: "strategy", line: ["e4"])], into: [], game: "g", budget: .persona)
        XCTAssertNil(out.first?.line)
    }

    func testInvalidItemsDropped() {
        var noRationale = item("a"); noRationale["rationale"] = ""
        var missingRationale = item("b"); missingRationale.removeValue(forKey: "rationale")
        var badCategory = item("c"); badCategory["category"] = "nonsense"
        var noStatement = item("d"); noStatement["statement"] = ""
        let out = MemoryUpdater.merge([noRationale, missingRationale, badCategory, noStatement, item("ok")], into: [], game: "g", budget: .persona)
        XCTAssertEqual(out.map(\.id), ["ok"])
    }

    func testEvidenceGainsGameOnlyWhenSeen() {
        let old = [note("a", evidence: ["g0"]), note("b", evidence: ["g0"])]
        let out = MemoryUpdater.merge([item("a", seen: true), item("b", seen: false), item("c", seen: true)], into: old, game: "g1", budget: .persona)
        XCTAssertEqual(out.first { $0.id == "a" }?.evidence, ["g0", "g1"])
        XCTAssertEqual(out.first { $0.id == "b" }?.evidence, ["g0"])
        XCTAssertEqual(out.first { $0.id == "c" }?.evidence, ["g1"])
    }

    func testEvidenceNotDuplicated() {
        let out = MemoryUpdater.merge([item("a", seen: true)], into: [note("a", evidence: ["g1"])], game: "g1", budget: .persona)
        XCTAssertEqual(out[0].evidence, ["g1"])
    }

    func testEmptyAnswerKeepsOldNotes() {
        let old = [note("a"), note("b")]
        XCTAssertEqual(MemoryUpdater.merge([], into: old, game: "g", budget: .persona), old)
    }

    func testConfidenceFallsBackToPreviousThenDefault() {
        var noConf = item("a"); noConf.removeValue(forKey: "confidence")
        var noConf2 = item("z"); noConf2.removeValue(forKey: "confidence")
        let out = MemoryUpdater.merge([noConf, noConf2], into: [note("a", confidence: 0.77)], game: "g", budget: .persona)
        XCTAssertEqual(out.first { $0.id == "a" }?.confidence, 0.77)
        XCTAssertEqual(out.first { $0.id == "z" }?.confidence, 0.3)
    }

    func testTextIsTruncated() {
        let out = MemoryUpdater.merge([item("a", extra: ["statement": String(repeating: "s", count: 500), "rationale": String(repeating: "r", count: 500)])], into: [], game: "g", budget: .persona)
        XCTAssertEqual(out[0].statement.count, 140)
        XCTAssertEqual(out[0].rationale.count, 220)
    }

    func testRecordAdd() {
        var r = Record()
        r.add(.whiteWins, as: .white); r.add(.whiteWins, as: .black); r.add(.draw, as: .white); r.add(.blackWins, as: .black); r.add(.ongoing, as: .white)
        XCTAssertEqual(r.text, "+2 =1 -1")
    }
}

final class MemoryUpdateEndToEndTests: XCTestCase {
    static let personaJSON: [String: Any] = [
        "summary": "A tidy win.", "style": "Sharper now.",
        "notes": [[
            "id": "open-e4", "category": "opening", "statement": "Plays e4", "rationale": "won with it",
            "line": ["e4", "e5", "Nf3"], "side": "white", "confidence": 0.7, "seenThisGame": true,
        ]],
    ]
    static let opponentJSON: [String: Any] = [
        "notes": [[
            "id": "late-castle", "category": "tendency", "statement": "Castles late", "rationale": "game 1",
            "confidence": 0.6, "seenThisGame": true,
        ]],
    ]

    func backend() -> FakeBackend {
        FakeBackend { request in
            if request.system.contains("self-knowledge") { return Self.personaJSON }
            if request.system.contains("scouting file") { return Self.opponentJSON }
            throw FakeFailure()
        }
    }

    func record(opponent: OpponentID, result: GameResult = .whiteWins) -> GameRecord {
        GameRecord(
            id: "game-1", date: Date(), personaID: "json-bourne", opponent: opponent, personaColor: .white, result: result,
            end: .checkmate, pgn: "1. e4 e5 *",
            notes: [MoveNote(ply: 0, san: "e4", byPersona: true, source: .book), MoveNote(ply: 1, san: "e5", byPersona: false)])
    }

    let review = GameReview(plies: [], persona: SideStats(), opponent: SideStats())

    func testSinglePlayerWritesPersonaAndDossier() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = backend()
        let updater = MemoryUpdater(router: makeRouter(fake), store: store)
        let ctx = singlePlayer(.human("alice"))
        let out = try await updater.update(record: record(opponent: .human("alice")), review: review, persona: MemoryStore.defaultPersona, context: ctx)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(out.persona.record.text, "+1 =0 -0")
        XCTAssertEqual(out.persona.style, "Sharper now.")
        XCTAssertEqual(out.record.summary, "A tidy win.")
        XCTAssertEqual(out.dossier?.record.text, "+1 =0 -0")

        let saved = try XCTUnwrap(store.persona("json-bourne"))
        XCTAssertEqual(saved.notes.map(\.id), ["open-e4"])
        XCTAssertEqual(saved.notes[0].evidence, ["game-1"])
        XCTAssertEqual(saved.record.games, 1)
        let dossier = try XCTUnwrap(store.dossier(.human("alice"), persona: "json-bourne", in: ctx))
        XCTAssertEqual(dossier.notes.map(\.id), ["late-castle"])
        XCTAssertEqual(dossier.record.wins, 1)
        XCTAssertEqual(store.games().map(\.id), ["game-1"])
        XCTAssertNotNil(store.games().first?.review)
        // The persona update never sees opponent notes: its prompt carries no dossier text.
        XCTAssertFalse(fake.requests[0].prompt.contains("Castles late"))
    }

    func testPvPLeavesHumanDossierUntouched() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var human = OpponentDossier(opponent: .human("alice"))
        human.notes = [note("h", .tendency, statement: "ALICE_NOTE")]
        try store.save(human, persona: "json-bourne", in: singlePlayer(.human("alice")))
        let humanFile = root.appendingPathComponent("personas/json-bourne/opponents/human-alice.json")
        let before = try Data(contentsOf: humanFile)

        let fake = backend()
        let updater = MemoryUpdater(router: makeRouter(fake), store: store)
        let ctx = pvp(.model("gpt"))
        let out = try await updater.update(record: record(opponent: .model("gpt"), result: .draw), review: review, persona: MemoryStore.defaultPersona, context: ctx)

        XCTAssertEqual(try Data(contentsOf: humanFile), before)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertFalse(fake.requests.contains { $0.prompt.contains("ALICE_NOTE") || $0.system.contains("ALICE_NOTE") })
        let modelFile = root.appendingPathComponent("personas/json-bourne/opponents/model-gpt.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelFile.path))
        XCTAssertEqual(out.dossier?.opponent, .model("gpt"))
        XCTAssertEqual(out.dossier?.record.draws, 1)
        XCTAssertEqual(store.dossier(.model("gpt"), persona: "json-bourne", in: ctx)?.notes.map(\.id), ["late-castle"])
        let files = try FileManager.default.contentsOfDirectory(atPath: humanFile.deletingLastPathComponent().path).sorted()
        XCTAssertEqual(files, ["human-alice.json", "model-gpt.json"])
    }

    func testEmptyModelAnswerKeepsOldNotes() async throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = FakeBackend { _ in [:] }
        var persona = MemoryStore.defaultPersona
        persona.notes = [note("keep")]
        let out = try await MemoryUpdater(router: makeRouter(fake), store: store)
            .update(record: record(opponent: .human("alice")), review: review, persona: persona, context: singlePlayer(.human("alice")))
        XCTAssertEqual(out.persona.notes.map(\.id), ["keep"])
        XCTAssertEqual(out.persona.style, persona.style)
        XCTAssertNil(out.record.summary)
    }
}
