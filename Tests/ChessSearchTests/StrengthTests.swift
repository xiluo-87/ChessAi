import XCTest
import ChessCore
import ChessEngine
@testable import ChessSearch

/// Measurements rather than checks, skipped unless asked for; run them in release:
///
///     CHESSAI_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter StrengthTests.testBenchmark
///     CHESSAI_MATCH=20 swift test -c release -Xswiftc -enable-testing --filter StrengthTests.testMatchAgainstStockfish
///
/// The match reads CHESSAI_MATCH_MS (our time per move, default 200), CHESSAI_MATCH_SF (Stockfish's setting:
/// "skill:N" for its Skill Level at the same time per move, or "depth:N"; default "skill:0") and CHESSAI_MATCH_PGN
/// (a file for the games).
final class StrengthTests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    func testBenchmark() async throws {
        guard env["CHESSAI_BENCH"] != nil else { throw XCTSkip("set CHESSAI_BENCH to run") }
        let clock = ContinuousClock()
        for (fen, depth) in [(SearchEngineTests.start, 5), (SearchEngineTests.kiwipete, 4)] {
            let board = try Board(fen: fen)
            let began = clock.now
            let nodes = board.perft(depth)
            let seconds = Self.seconds(clock.now - began)
            print("perft \(depth) \(nodes) nodes in \(String(format: "%.2f", seconds)) s: \(Int(Double(nodes) / seconds)) nps (\(fen))")
        }
        let positions = [
            SearchEngineTests.start,
            SearchEngineTests.kiwipete,
            "r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P4/2PBPN2/PP1N1PPP/R1BQ1RK1 w - - 0 8",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "2r3k1/5ppp/8/8/8/8/1q3PPP/3R1RK1 w - - 0 1",
        ]
        var nodes = 0, ms = 0
        for fen in positions {
            for multiPV in [1, 4] {
                let e = SearchEngine(hashMB: 64)
                await e.start()
                let lines = try await e.analyse(fen: fen, moves: [], multiPV: multiPV, limits: EngineLimits(movetimeMs: 3000))
                let last = await e.lastSearch
                let stats = try XCTUnwrap(last)
                nodes += stats.nodes; ms += stats.milliseconds
                print("search multipv \(multiPV): depth \(stats.depth), \(stats.nodes) nodes, \(stats.nodesPerSecond) nps, "
                      + "best \(lines[0].move) \(lines[0].score.description) (\(fen))")
            }
        }
        print("search overall: \(nodes * 1000 / max(1, ms)) nps")
        for depth in [8, 10, 12] {
            let e = SearchEngine(hashMB: 64)
            await e.start()
            let began = clock.now
            _ = try await e.analyse(fen: positions[2], moves: [], multiPV: 4, limits: EngineLimits(depth: depth))
            print("middlegame to depth \(depth), multipv 4: \(String(format: "%.2f", Self.seconds(clock.now - began))) s")
        }
    }

    /// Short balanced openings, each played once with either colour.
    static let openings: [[String]] = [
        ["e2e4", "e7e5", "g1f3", "b8c6"],
        ["d2d4", "d7d5", "c2c4", "e7e6"],
        ["e2e4", "c7c5", "g1f3", "d7d6"],
        ["d2d4", "g8f6", "c2c4", "g7g6"],
        ["c2c4", "e7e5", "b1c3", "g8f6"],
        ["e2e4", "e7e6", "d2d4", "d7d5"],
        ["e2e4", "c7c6", "d2d4", "d7d5"],
        ["g1f3", "d7d5", "g2g3", "g8f6"],
        ["d2d4", "d7d5", "g1f3", "g8f6"],
        ["e2e4", "e7e5", "f1c4", "g8f6"],
    ]

    func testMatchAgainstStockfish() async throws {
        guard let count = env["CHESSAI_MATCH"].flatMap(Int.init) else { throw XCTSkip("set CHESSAI_MATCH to run") }
        guard StockfishEngine.locate() != nil else { throw XCTSkip("stockfish not installed") }
        let ms = env["CHESSAI_MATCH_MS"].flatMap(Int.init) ?? 200
        let setting = env["CHESSAI_MATCH_SF"] ?? "skill:0"
        let parts = setting.split(separator: ":")
        let value = parts.count == 2 ? Int(parts[1]) : nil
        let stockfish = try StockfishEngine()
        try await stockfish.start(threads: 1, hashMB: 16)
        var sfLimits = EngineLimits(movetimeMs: ms)
        if parts.first == "skill", let value {
            try await stockfish.setOption(name: "Skill Level", value: String(value))
        } else if parts.first == "depth", let value {
            sfLimits = EngineLimits(depth: value)
        }
        let ours = SearchEngine(hashMB: 32)
        await ours.start()

        var points = 0.0
        var pgn = ""
        var tally = (wins: 0, draws: 0, losses: 0)
        for i in 0..<count {
            let opening = Self.openings[(i / 2) % Self.openings.count]
            let oursWhite = i % 2 == 0
            try await stockfish.newGame()
            await ours.newGame()
            var game = Game()
            for uci in opening { game.play(Move(uci: uci)!) }
            while game.result == .ongoing && game.moves.count < 300 {
                let oursToMove = (game.current.sideToMove == .white) == oursWhite
                let history = game.moves.map(\.uci)
                let uci = oursToMove
                    ? try await ours.bestMove(fen: Position.start.fen, moves: history, limits: EngineLimits(movetimeMs: ms))
                    : try await stockfish.bestMove(fen: Position.start.fen, moves: history, limits: sfLimits)
                guard let uci, let move = Move(uci: uci), game.play(move) else {
                    XCTFail("no legal move from \(oursToMove ? "ChessSearch" : "Stockfish") in \(game.current.fen)")
                    break
                }
            }
            let result = game.result
            let score: Double = result == .draw || result == .ongoing ? 0.5
                : (result == .whiteWins) == oursWhite ? 1 : 0
            points += score
            if score == 1 { tally.wins += 1 } else if score == 0 { tally.losses += 1 } else { tally.draws += 1 }
            let white = oursWhite ? "ChessSearch \(ms) ms" : "Stockfish \(setting)"
            let black = oursWhite ? "Stockfish \(setting)" : "ChessSearch \(ms) ms"
            let ending = game.end?.rawValue ?? "move limit"
            print("game \(i + 1): \(white) - \(black) \(result.rawValue) (\(ending), \(game.moves.count) plies)")
            pgn += game.pgn(tags: [("Event", "ChessSearch vs Stockfish"), ("Round", "\(i + 1)"), ("White", white),
                                   ("Black", black), ("Result", result == .ongoing ? "1/2-1/2" : result.rawValue),
                                   ("Termination", ending)]) + "\n"
        }
        let share = points / Double(count)
        let elo = share <= 0 || share >= 1 ? "n/a" : String(format: "%+.0f", -400 * log10(1 / share - 1))
        print("ChessSearch \(ms) ms vs Stockfish \(setting): +\(tally.wins) =\(tally.draws) -\(tally.losses), "
              + "\(points)/\(count), Elo difference \(elo)")
        if let path = env["CHESSAI_MATCH_PGN"] { try pgn.write(toFile: path, atomically: true, encoding: .utf8) }
        await stockfish.shutdown()
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
