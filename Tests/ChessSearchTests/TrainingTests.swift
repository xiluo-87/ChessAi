import XCTest
import ChessCore
@testable import ChessSearch

final class TrainingTests: XCTestCase {
    /// The same position with colours swapped and the board turned over.
    static func mirrored(_ fen: String) -> String {
        let parts = fen.split(separator: " ").map(String.init)
        let rows = parts[0].split(separator: "/").reversed().map { row in
            String(row.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        }
        let castling = parts[2] == "-" ? "-" : String(parts[2].map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) }
            .sorted { ("KQkq".firstIndex(of: $0)!) < ("KQkq".firstIndex(of: $1)!) })
        let ep = parts[3] == "-" ? "-" : String(parts[3].first!) + (parts[3].last == "3" ? "6" : "3")
        return "\(rows.joined(separator: "/")) \(parts[1] == "w" ? "b" : "w") \(castling) \(ep) \(parts[4]) \(parts[5])"
    }

    /// Along random games: White's view equals Black's in the mirrored position, the training features give the
    /// board's own evaluation, and the board writes a FEN that reads back to the same position.
    func testEvaluationIsSymmetricAndMatchesFeatures() throws {
        var rng = SplitMix64(seed: 3)
        for _ in 0..<20 {
            var position = Position.start
            for _ in 0..<60 {
                let legal = position.legalMoves()
                guard !legal.isEmpty else { break }
                position = position.applying(legal[Int(rng.next() % UInt64(legal.count))])
                let board = try Board(fen: position.fen)
                let flipped = try Board(fen: Self.mirrored(position.fen))
                XCTAssertEqual(board.evaluate(), flipped.evaluate(), position.fen)
                XCTAssertEqual(try Board(fen: board.fen).hash, board.hash)
                let features = Training.Features([TrainingPosition(fen: position.fen, result: 0.5)])
                let w = (EvalWeights.standard.middlegame + EvalWeights.standard.endgame).flatMap { $0 }.map(Double.init)
                let white = board.side == 0 ? board.evaluate() : -board.evaluate()
                XCTAssertEqual(features.evaluation(0, w), Double(white), accuracy: 1, position.fen)
            }
        }
    }

    func testWeightsRoundTripAndShape() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("weights-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var tagged = EvalWeights.standard
        tagged.round = 3; tagged.positions = 1234; tagged.note = "a \"quoted\" note"
        try tagged.write(to: url)
        XCTAssertEqual(try EvalWeights(contentsOf: url), tagged)
        XCTAssertTrue(tagged.sameValues(as: .standard))
        // Files from before the tags read as round 0.
        try #"{"middlegame": \#(EvalWeights.standard.middlegame), "endgame": \#(EvalWeights.standard.endgame)}"#
            .write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try EvalWeights(contentsOf: url), .standard.withNote(""))
        XCTAssertThrowsError(try EvalWeights(middlegame: [[0]], endgame: [[0]]))
        // A pawn on its fifth rank: material plus placement.
        XCTAssertEqual(EvalWeights.standard.middlegame[0][Squares.parse("e5")!], 100 + 12 + 14)
    }

    /// Round 0 is the standard values, tagged and written exactly as `write(to:)` writes them; every round after it
    /// is tagged with its number and the positions it was fitted to.
    func testBundledRounds() throws {
        let rounds = EvalWeights.bundledRounds
        XCTAssertGreaterThanOrEqual(rounds.count, 2)
        XCTAssertEqual(rounds, Array(0..<rounds.count))
        let zero = try EvalWeights.bundled(round: 0)
        XCTAssertEqual(zero, .standard)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("round-0-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try EvalWeights.standard.write(to: url)
        let bundledURL = try XCTUnwrap(Bundle.module.url(forResource: "round-0", withExtension: "json", subdirectory: "Weights"))
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: bundledURL))
        for round in rounds.dropFirst() {
            let w = try EvalWeights.bundled(round: round)
            XCTAssertEqual(w.round, round)
            XCTAssertGreaterThan(w.positions, 0)
            XCTAssertTrue(w.note.hasPrefix("Round \(round):"), w.note)
            XCTAssertFalse(w.sameValues(as: try EvalWeights.bundled(round: round - 1)))
        }
        XCTAssertThrowsError(try EvalWeights.bundled(round: rounds.count))
    }

    func testSearchEngineUsesItsWeights() async throws {
        // Knights worth nothing: a knight against a pawn is then a pawn down.
        var weights = EvalWeights.standard
        weights.middlegame[1] = Array(repeating: 0, count: 64)
        weights.endgame[1] = Array(repeating: 0, count: 64)
        let fen = "4k3/8/8/3p4/8/8/8/N3K3 w - - 0 1"
        let normal = SearchEngine(), cheap = SearchEngine(weights: weights)
        await normal.start(); await cheap.start()
        let a = try await normal.analyse(fen: fen, moves: [], multiPV: 1, limits: EngineLimits(depth: 3))
        let b = try await cheap.analyse(fen: fen, moves: [], multiPV: 1, limits: EngineLimits(depth: 3))
        XCTAssertGreaterThan(try XCTUnwrap(a.first).score.normalized, 100)
        XCTAssertLessThan(try XCTUnwrap(b.first).score.normalized, 0)
    }

    func testSANMatchesChessCore() throws {
        var rng = SplitMix64(seed: 11)
        for _ in 0..<10 {
            var position = Position.start
            let board = try Board(fen: Position.start.fen, searchPlies: 200)
            for _ in 0..<120 {
                let legal = position.legalMoves()
                guard !legal.isEmpty else { break }
                let move = legal[Int(rng.next() % UInt64(legal.count))]
                let parsed = try XCTUnwrap(Training.move(fromSAN: position.san(for: move), on: board), position.san(for: move))
                XCTAssertEqual(parsed.uci, move.uci)
                board.make(parsed)
                position = position.applying(move)
            }
        }
    }

    func testPositionsFromPGN() throws {
        let pgn = """
        [Event "One"]
        [Result "1-0"]

        1. e4 e5 2. Nf3 {a comment (with brackets)} Nc6 3. Bb5 a6 (3... Nf6 4. O-O) 4. Ba4 Nf6 5. O-O Be7
        6. Re1 b5 7. Bb3 d6 $1 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 1-0

        [Event "Two"]
        [Result "*"]

        1. d4 d5 *

        [Event "Three"]
        [FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]
        [Result "1/2-1/2"]

        1. Kd2 Kd8 2. Kd3 Kd7 3. e4 Ke7 4. Kd4 Kd6 5. e5+ Ke6 6. Ke4 Ke7 7. Kd5 Kd7 8. e6+ Ke7 9. Ke5 Ke8
        10. Kd6 Kd8 11. e7+ Ke8 12. Ke6 1/2-1/2
        """
        let positions = Training.positions(fromPGN: pgn)
        let first = positions.filter { $0.result == 1 }, third = positions.filter { $0.result == 0.5 }
        // From ply 8 on, quiet positions only (a few of the 20 plies are captures or checks).
        XCTAssertGreaterThan(first.count, 6)
        XCTAssertLessThanOrEqual(first.count, 13)
        XCTAssertFalse(third.isEmpty)
        XCTAssertEqual(positions.count, first.count + third.count)
        for p in positions { XCTAssertFalse(try Board(fen: p.fen).inCheck) }
        XCTAssertTrue(first.contains { $0.fen.hasPrefix("r1bq1rk1/2pnbppp/p2p1n2/1p2p3/3PP3/1BP2N1P/PP3PP1/RNBQR1K1 w") })
    }

    func testFileRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("positions-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        let positions = [TrainingPosition(fen: Position.start.fen, result: 0.5),
                         TrainingPosition(fen: "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", result: 1)]
        try Training.write(positions, to: url)
        XCTAssertEqual(try Training.read(from: url), positions)
    }

    /// The whole loop at toy size: self-play, tune, compare.
    func testSelfPlayTuneAndCompare() throws {
        let positions = Training.selfPlay(games: 4, depth: 2, randomPlies: 6, seed: 5)
        XCTAssertGreaterThan(positions.count, 20)
        for p in positions.prefix(50) {
            XCTAssertTrue([0, 0.5, 1].contains(p.result))
            XCTAssertFalse(try Board(fen: p.fen).inCheck)
        }
        let (tuned, report) = Training.tune(positions, epochs: 40)
        XCTAssertLessThan(report.lossAfter, report.lossBefore)
        XCTAssertFalse(tuned.sameValues(as: .standard))
        XCTAssertEqual(tuned.round, 1)
        XCTAssertEqual(tuned.positions, report.trainingPositions)
        var next = tuned
        next.round = 4
        XCTAssertEqual(Training.tune(positions, from: next, epochs: 2).weights.round, 5)
        let tally = Training.compare(tuned, against: .standard, games: 2, depth: 1)
        XCTAssertEqual(tally.games, 2)
    }

    func testTallyElo() {
        XCTAssertEqual(MatchTally(wins: 5, draws: 0, losses: 5).eloDifference ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(MatchTally(wins: 3, draws: 0, losses: 1).eloDifference ?? 0, 190.8, accuracy: 0.1)
        XCTAssertNil(MatchTally(wins: 2, draws: 0, losses: 0).eloDifference)
    }
}

extension EvalWeights {
    func withNote(_ note: String) -> EvalWeights {
        var w = self
        w.note = note
        return w
    }
}
