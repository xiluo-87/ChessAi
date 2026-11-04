import XCTest
@testable import ChessEngine

final class StockfishEngineTests: XCTestCase {
    private func makeEngine() async throws -> StockfishEngine {
        guard StockfishEngine.locate() != nil else { throw XCTSkip("stockfish not installed") }
        let e = try StockfishEngine()
        try await e.start()
        return e
    }

    func testScoreDescription() {
        XCTAssertEqual(EngineScore(centipawns: 35, mate: nil).description, "+0.35")
        XCTAssertEqual(EngineScore(centipawns: -120, mate: nil).description, "-1.20")
        XCTAssertEqual(EngineScore(centipawns: 0, mate: nil).description, "+0.00")
        XCTAssertEqual(EngineScore(centipawns: nil, mate: 3).description, "#3")
        XCTAssertEqual(EngineScore(centipawns: nil, mate: -2).description, "#-2")
    }

    func testScoreFlipAndNormalized() {
        XCTAssertEqual(EngineScore(centipawns: 50, mate: nil).flipped(), EngineScore(centipawns: -50, mate: nil))
        XCTAssertEqual(EngineScore(centipawns: nil, mate: 2).flipped(), EngineScore(centipawns: nil, mate: -2))
        XCTAssertEqual(EngineScore(centipawns: 77, mate: nil).normalized, 77)
        XCTAssertEqual(EngineScore(centipawns: nil, mate: 3).normalized, 99_700)
        XCTAssertEqual(EngineScore(centipawns: nil, mate: -1).normalized, -99_900)
    }

    func testParseInfo() {
        let l = "info depth 10 seldepth 12 multipv 2 score cp 31 nodes 1 pv e2e4 e7e5"
        let (k, line) = StockfishEngine.parseInfo(l)!
        XCTAssertEqual(k, 2)
        XCTAssertEqual(line.move, "e2e4")
        XCTAssertEqual(line.pv.count, 2)
        XCTAssertNil(StockfishEngine.parseInfo("info depth 5 score cp 10 lowerbound pv e2e4"))
        XCTAssertNil(StockfishEngine.parseInfo("info depth 5 currmove e2e4"))
    }

    func testAnalyseStartPositionMultiPV() async throws {
        let e = try await makeEngine()
        let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let lines = try await e.analyse(fen: fen, multiPV: 3, limits: EngineLimits(depth: 10))
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(Set(lines.map(\.move)).count, 3)
        for l in lines {
            XCTAssertTrue(l.move.count == 4 || l.move.count == 5)
            XCTAssertNotNil(l.score.centipawns)
            XCTAssertFalse(l.pv.isEmpty)
        }
        await e.shutdown()
    }

    func testMateInOne() async throws {
        let e = try await makeEngine()
        let fen = "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1"
        let best = try await e.bestMove(fen: fen, limits: EngineLimits(depth: 8))
        XCTAssertEqual(best, "d1d8")
        let lines = try await e.analyse(fen: fen, multiPV: 1, limits: EngineLimits(depth: 8))
        XCTAssertEqual(lines.first?.score.mate, 1)
        await e.shutdown()
    }

    func testNoLegalMove() async throws {
        let e = try await makeEngine()
        let best = try await e.bestMove(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", limits: EngineLimits(depth: 5))
        XCTAssertNil(best)
        await e.shutdown()
    }

    func testShutdownTwiceAndTerminated() async throws {
        let e = try await makeEngine()
        await e.shutdown()
        await e.shutdown()
        do {
            _ = try await e.bestMove(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1", limits: EngineLimits(depth: 3))
            XCTFail("expected terminated")
        } catch EngineError.terminated {}
    }

    /// Regression: overlapping calls (the app starts a new game while the persona already searches) used to share
    /// the engine's output stream, dropping a waiter's continuation and leaving that call suspended forever.
    func testOverlappingCallsAllComplete() async throws {
        let engine = try await makeEngine()
        defer { Task { await engine.shutdown() } }
        let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        let mate = "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1"
        async let a = engine.analyse(fen: start, multiPV: 3, limits: EngineLimits(depth: 10))
        async let reset: Void = engine.newGame()
        async let b = engine.bestMove(fen: mate, limits: EngineLimits(depth: 6))
        async let c = engine.analyse(fen: mate, multiPV: 1, limits: EngineLimits(depth: 6))
        let (lines, _, best, mateLines) = try await (a, reset, b, c)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(best, "d1d8")
        XCTAssertEqual(mateLines.first?.score.mate, 1)
    }

    /// Regression: the engine was given only the current position, so it rated a third repetition as winning (+5.2)
    /// and JSON Bourne walked into a draw (Lichess game 8L5R3JaG). With the game's moves it sees the draw.
    func testHistoryRevealsRepetition() async throws {
        let engine = try await makeEngine()
        defer { Task { await engine.shutdown() } }
        let repeating = "c8c7"
        let alone = try await engine.analyse(
            fen: "2k5/8/p1P4p/1pK5/6P1/8/8/8 b - - 8 52", multiPV: 4, limits: EngineLimits(depth: 14))
        XCTAssertGreaterThan(try XCTUnwrap(alone.first { $0.move == repeating }).score.normalized, 200)
        let withHistory = try await engine.analyse(
            fen: "8/2k5/p1P4p/1pK5/6P1/8/8/8 w - - 0 47",
            moves: ["c5d5", "c7c8", "d5c5", "c8c7", "c5d5", "c7b8", "d5d6", "b8c8", "d6c5"],
            multiPV: 4, limits: EngineLimits(depth: 14))
        XCTAssertEqual(try XCTUnwrap(withHistory.first { $0.move == repeating }).score.normalized, 0)
    }
}
