import XCTest
import ChessCore
@testable import ChessSearch

final class SearchEngineTests: XCTestCase {
    static let start = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    static let kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"

    private func makeEngine() async -> SearchEngine {
        let e = SearchEngine(hashMB: 16)
        await e.start()
        return e
    }

    /// Mates with the move that starts them, each confirmed by Stockfish 16.
    func testFindsMates() async throws {
        let e = await makeEngine()
        let cases: [(fen: String, move: String, mate: Int)] = [
            ("6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1", "d1d8", 1),
            ("r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1", "f3f7", 1),
            ("r2qkb1r/pp2nppp/3p4/2pNN1B1/2BnP3/3P4/PPP2PPP/R2bK2R w KQkq - 1 1", "d5f6", 2),
            ("6k1/pp4p1/2p5/2bp4/8/P5Pb/1P3rrP/2BRRN1K b - - 0 1", "g2g1", 2),
            ("r1b1kb1r/pppp1ppp/5q2/4n3/3KP3/2N3PN/PPP4P/R1BQ1B1R b kq - 0 1", "f8c5", 3),
        ]
        for c in cases {
            let lines = try await e.analyse(fen: c.fen, moves: [], multiPV: 1, limits: EngineLimits(depth: 2 * c.mate + 1))
            XCTAssertEqual(lines.first?.move, c.move, c.fen)
            XCTAssertEqual(lines.first?.score.mate, c.mate, c.fen)
            XCTAssertEqual(lines.first?.pv.count, 2 * c.mate - 1, c.fen)
        }
    }

    /// The side being mated sees it coming, with a negative mate count.
    func testReportsBeingMated() async throws {
        let e = await makeEngine()
        // After 1. Nf6+ in the mate in two: every reply allows Bxf7#.
        let lines = try await e.analyse(
            fen: "r2qkb1r/pp2nppp/3p4/2pNN1B1/2BnP3/3P4/PPP2PPP/R2bK2R w KQkq - 1 1", moves: ["d5f6"], multiPV: 1,
            limits: EngineLimits(depth: 4))
        XCTAssertEqual(lines.first?.score.mate, -1)
    }

    func testWinsMaterialWithAFork() async throws {
        let e = await makeEngine()
        let lines = try await e.analyse(fen: "q3k3/8/8/1N6/8/8/8/4K3 w - - 0 1", moves: [], multiPV: 2, limits: EngineLimits(depth: 6))
        XCTAssertEqual(lines.first?.move, "b5c7")
        // The fork leads by far more than MovePicker's 150 cp obvious-move gap.
        XCTAssertGreaterThan(lines[0].score.normalized - lines[1].score.normalized, 300)
    }

    func testDoesNotTakeADefendedPawnWithTheQueen() async throws {
        let e = await makeEngine()
        let best = try await e.bestMove(fen: "4k3/8/4p3/3p4/8/8/8/3QK3 w - - 0 1", moves: [], limits: EngineLimits(depth: 5))
        XCTAssertNotEqual(best, "d1d5")
    }

    func testMultiPVLinesAreDistinctLegalAndBestFirst() async throws {
        let e = await makeEngine()
        for fen in [Self.start, Self.kiwipete] {
            let lines = try await e.analyse(fen: fen, moves: [], multiPV: 4, limits: EngineLimits(depth: 5))
            XCTAssertEqual(lines.count, 4)
            XCTAssertEqual(Set(lines.map(\.move)).count, 4)
            XCTAssertEqual(lines.map(\.score.normalized), lines.map(\.score.normalized).sorted(by: >))
            let position = Position(fen: fen)!
            for line in lines {
                XCTAssertEqual(line.depth, 5)
                XCTAssertEqual(line.pv.first, line.move)
                XCTAssertNotNil(line.score.centipawns)
                // The whole principal variation is playable.
                var p = position
                for uci in line.pv {
                    let move = try XCTUnwrap(Move(uci: uci))
                    XCTAssertTrue(p.isLegal(move), "\(uci) in \(p.fen)")
                    p = p.applying(move)
                }
            }
            let single = try await e.analyse(fen: fen, moves: [], multiPV: 1, limits: EngineLimits(depth: 5))
            XCTAssertEqual(single.count, 1)
        }
    }

    func testMultiPVStopsAtTheLegalMoveCount() async throws {
        let e = await makeEngine()
        // The king can take the pawn or go to b2; b1 is covered by the pawn.
        let lines = try await e.analyse(fen: "k7/8/8/8/8/8/p7/K7 w - - 0 1", moves: [], multiPV: 10, limits: EngineLimits(depth: 3))
        XCTAssertEqual(Set(lines.map(\.move)), ["a1a2", "a1b2"])
        XCTAssertEqual(lines.first?.move, "a1a2")
    }

    /// The same history as `StockfishEngineTests.testHistoryRevealsRepetition` (Lichess game 8L5R3JaG): from the
    /// FEN alone c8c7 is an ordinary move; with the game's moves it is the third repetition, a draw.
    func testHistoryRevealsRepetition() async throws {
        let e = await makeEngine()
        let repeating = "c8c7"
        let alone = try await e.analyse(
            fen: "2k5/8/p1P4p/1pK5/6P1/8/8/8 b - - 8 52", moves: [], multiPV: 4, limits: EngineLimits(depth: 8))
        XCTAssertNotEqual(try XCTUnwrap(alone.first { $0.move == repeating }).score.normalized, 0)
        let withHistory = try await e.analyse(
            fen: "8/2k5/p1P4p/1pK5/6P1/8/8/8 w - - 0 47",
            moves: ["c5d5", "c7c8", "d5c5", "c8c7", "c5d5", "c7b8", "d5d6", "b8c8", "d6c5"],
            multiPV: 4, limits: EngineLimits(depth: 8))
        XCTAssertEqual(try XCTUnwrap(withHistory.first { $0.move == repeating }).score.normalized, 0)
    }

    /// Winning with a queen up, the engine does not play the move that repeats the position a third time.
    func testWinningSideAvoidsThreefold() async throws {
        let fen = "7k/8/8/8/8/2K5/8/3Q4 b - - 0 1"
        let history = ["h8g8", "d1e1", "g8h8", "e1d1", "h8g8", "d1e1", "g8h8"]
        var game = Game(start: Position(fen: fen)!)
        for uci in history { XCTAssertTrue(game.play(Move(uci: uci)!)) }
        var drawn = game
        drawn.play(Move(uci: "e1d1")!)
        XCTAssertEqual(drawn.end, .threefoldRepetition)

        let e = await makeEngine()
        let all = try await e.analyse(fen: fen, moves: history, multiPV: 40, limits: EngineLimits(depth: 4))
        XCTAssertEqual(all.count, game.current.legalMoves().count)
        XCTAssertEqual(try XCTUnwrap(all.first { $0.move == "e1d1" }).score.normalized, 0)
        XCTAssertGreaterThan(all[0].score.normalized, 500)
        let best = try await e.bestMove(fen: fen, moves: history, limits: EngineLimits(depth: 6))
        XCTAssertNotEqual(best, "e1d1")
    }

    func testDepthLimitIsReported() async throws {
        let e = await makeEngine()
        for depth in [1, 3, 6] {
            let lines = try await e.analyse(fen: Self.kiwipete, moves: [], multiPV: 2, limits: EngineLimits(depth: depth))
            XCTAssertEqual(lines.map(\.depth), [depth, depth])
            let stats = await e.lastSearch
            XCTAssertEqual(stats?.depth, depth)
        }
    }

    func testMovetimeIsKept() async throws {
        let e = await makeEngine()
        for ms in [50, 300] {
            let clock = ContinuousClock()
            let began = clock.now
            let lines = try await e.analyse(fen: Self.kiwipete, moves: [], multiPV: 3, limits: EngineLimits(movetimeMs: ms))
            let elapsed = clock.now - began
            XCTAssertEqual(lines.count, 3)
            XCTAssertLessThan(elapsed, .milliseconds(ms + 100), "movetime \(ms)")
        }
        // With both limits the first one reached ends the search.
        let clock = ContinuousClock()
        let began = clock.now
        let lines = try await e.analyse(fen: Self.kiwipete, moves: [], multiPV: 1, limits: EngineLimits(depth: 40, movetimeMs: 200))
        XCTAssertLessThan(clock.now - began, .milliseconds(300))
        XCTAssertFalse(lines.isEmpty)
    }

    func testCancellationStopsTheSearch() async throws {
        let e = await makeEngine()
        let task = Task { try await e.analyse(fen: Self.kiwipete, moves: [], multiPV: 1, limits: EngineLimits(depth: 40)) }
        try await Task.sleep(for: .milliseconds(150))
        let clock = ContinuousClock()
        let began = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertLessThan(clock.now - began, .milliseconds(100))
        // The engine is free again afterwards.
        let best = try await e.bestMove(fen: Self.start, moves: [], limits: EngineLimits(depth: 3))
        XCTAssertNotNil(best)
    }

    func testOverlappingCallsAllComplete() async throws {
        let e = await makeEngine()
        let mate = "6k1/5ppp/8/8/8/8/5PPP/3R2K1 w - - 0 1"
        async let a = e.analyse(fen: Self.start, multiPV: 3, limits: EngineLimits(depth: 5))
        async let reset: Void = e.newGame()
        async let b = e.bestMove(fen: mate, limits: EngineLimits(depth: 4))
        async let c = e.analyse(fen: mate, multiPV: 1, limits: EngineLimits(depth: 4))
        let (lines, _, best, mateLines) = try await (a, reset, b, c)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(best, "d1d8")
        XCTAssertEqual(mateLines.first?.score.mate, 1)
    }

    func testNoLegalMove() async throws {
        let e = await makeEngine()
        let checkmated = "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1", stalemated = "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"
        let best = try await e.bestMove(fen: checkmated, moves: [], limits: EngineLimits(depth: 5))
        XCTAssertNil(best)
        let none = try await e.analyse(fen: stalemated, moves: [], multiPV: 3, limits: EngineLimits(depth: 5))
        XCTAssertTrue(none.isEmpty)
    }

    func testDrawnEndingsScoreZero() async throws {
        let e = await makeEngine()
        let bareKnight = try await e.analyse(fen: "8/8/4k3/8/8/3NK3/8/8 w - - 0 1", moves: [], multiPV: 1, limits: EngineLimits(depth: 6))
        XCTAssertEqual(bareKnight.first?.score.normalized, 0)
    }

    func testBadInputAndShutdown() async throws {
        let e = await makeEngine()
        do {
            _ = try await e.bestMove(fen: Self.start, moves: ["e2e5"], limits: EngineLimits(depth: 2))
            XCTFail("expected an error")
        } catch EngineError.noResponse {}
        await e.shutdown()
        await e.shutdown()
        do {
            _ = try await e.bestMove(fen: Self.start, moves: [], limits: EngineLimits(depth: 2))
            XCTFail("expected terminated")
        } catch EngineError.terminated {}
        await e.start()
        let best = try await e.bestMove(fen: Self.start, moves: [], limits: EngineLimits(depth: 2))
        XCTAssertNotNil(best)
    }

    func testScoreConversion() {
        XCTAssertEqual(Searcher.engineScore(mateScore - 1), EngineScore(centipawns: nil, mate: 1))
        XCTAssertEqual(Searcher.engineScore(mateScore - 3), EngineScore(centipawns: nil, mate: 2))
        XCTAssertEqual(Searcher.engineScore(-mateScore + 2), EngineScore(centipawns: nil, mate: -1))
        XCTAssertEqual(Searcher.engineScore(-mateScore + 4), EngineScore(centipawns: nil, mate: -2))
        XCTAssertEqual(Searcher.engineScore(42), EngineScore(centipawns: 42, mate: nil))
        XCTAssertEqual(Searcher.fromTable(Searcher.toTable(mateScore - 7, 3), 5), mateScore - 9)
    }

    /// The engine through the protocol, as MovePicker uses it.
    func testUsableAsAnalysisEngine() async throws {
        let engine: any AnalysisEngine = SearchEngine()
        try await engine.start()
        try await engine.newGame()
        let lines = try await engine.analyse(fen: Self.start, moves: ["e2e4", "e7e5"], multiPV: 2, limits: EngineLimits(depth: 4))
        XCTAssertEqual(lines.count, 2)
        await engine.shutdown()
    }
}
