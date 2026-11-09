import XCTest
@testable import ChessCore

/// Scores positions from a table (side to move, centipawns), 0 for any other position.
private actor TableEngine: AnalysisEngine {
    nonisolated let name = "table"
    let scores: [String: Int]
    let failing: Set<String>

    init(_ scores: [String: Int], failing: Set<String> = []) {
        self.scores = scores
        self.failing = failing
    }

    func start() {}
    func newGame() {}
    func shutdown() {}

    func analyse(fen: String, moves: [String], multiPV: Int, limits: EngineLimits) throws -> [EngineLine] {
        let position = Position(fen: fen)!
        if failing.contains(OpeningBook.key(position)) { throw EngineError.noResponse("search timed out") }
        let move = position.legalMoves().first!.uci
        return [EngineLine(move: move, score: EngineScore(centipawns: scores[OpeningBook.key(position)] ?? 0, mate: nil), pv: [move], depth: 1)]
    }

    func bestMove(fen: String, moves: [String], limits: EngineLimits) throws -> String? {
        Position(fen: fen)!.legalMoves().first?.uci
    }
}

final class OpeningBookTests: XCTestCase {
    private func after(_ sans: String...) -> Position {
        sans.reduce(Position.start) { position, san in position.applying(position.move(fromSAN: san)!) }
    }

    func testTextRoundTripsAndSkipsComments() throws {
        let text = "# a comment\n\n\(OpeningBook.key(.start)) ; e2e4 3 d2d4 1\n"
        let book = try OpeningBook(text: text)
        XCTAssertEqual(book.count, 1)
        XCTAssertEqual(book.moves(at: .start), [.init(move: "e2e4", weight: 3), .init(move: "d2d4", weight: 1)])
        XCTAssertEqual(try OpeningBook(text: book.text()).moves(at: .start), book.moves(at: .start))
    }

    func testBadLinesAreRejected() {
        XCTAssertThrowsError(try OpeningBook(text: "no separator here"))
        XCTAssertThrowsError(try OpeningBook(text: "\(OpeningBook.key(.start)) ; e2e4"))
        XCTAssertThrowsError(try OpeningBook(text: "\(OpeningBook.key(.start)) ; e2e4 zero"))
    }

    func testIllegalMovesAreNeverOffered() throws {
        let book = try OpeningBook(text: "\(OpeningBook.key(.start)) ; e2e5 9 g1f3 1\n")
        XCTAssertEqual(book.moves(at: .start).map(\.move), ["g1f3"])
        XCTAssertEqual(book.pick(at: .start)?.uci, "g1f3")
        XCTAssertNil(book.pick(at: after("e4")))
    }

    func testTransposedPositionsShareAnEntry() {
        XCTAssertEqual(OpeningBook.key(after("Nf3", "Nf6", "g3")), OpeningBook.key(after("g3", "Nf6", "Nf3")))
    }

    func testLinesAreReadFromTheTSVColumn() {
        let tsv = "eco\tname\tpgn\nC20\tKing's Pawn Game\t1. e4 e5\nA00\tGrob Opening\t1. g4\n"
        XCTAssertEqual(OpeningBook.lines(fromTSV: tsv), [["e4", "e5"], ["g4"]])
        XCTAssertEqual(OpeningBook.lines(fromTSV: "eco\tname\nC20\tno pgn column\n"), [])
    }

    func testBuildKeepsOnlyMovesWithinTheMargin() async throws {
        let key = OpeningBook.key
        let engine = TableEngine([
            key(.start): 30,
            key(after("e4")): -30,         // e4 keeps White's 30: no loss
            key(after("d4")): -25,         // 5 worse than best
            key(after("e4", "e5")): 35,    // 5 worse for Black than the best
            key(after("e4", "c5")): 100,   // 70 worse: dropped
            key(after("e4", "e5", "Nf3")): -35,
            key(after("e4", "e5", "Qh5")): 50,  // 85 worse: dropped
        ])
        let lines = [["e4", "e5", "Nf3"], ["e4", "c5"], ["e4", "e5", "Qh5"], ["d4", "Zz9"]]
        let book = try await OpeningBook.build(lines: lines, plies: 16, marginCp: 50, engine: engine, limits: EngineLimits(depth: 1))
        XCTAssertEqual(book.moves(at: .start), [.init(move: "e2e4", weight: 3), .init(move: "d2d4", weight: 1)])
        XCTAssertEqual(book.moves(at: after("e4")), [.init(move: "e7e5", weight: 2)])
        XCTAssertEqual(book.moves(at: after("e4", "e5")), [.init(move: "g1f3", weight: 1)])
        XCTAssertTrue(book.moves(at: after("d4")).isEmpty, "a line stops at its illegal move")

        let short = try await OpeningBook.build(lines: lines, plies: 1, marginCp: 50, engine: engine, limits: EngineLimits(depth: 1))
        XCTAssertTrue(short.moves(at: after("e4")).isEmpty, "lines are cut after the ply limit")
    }

    func testAPositionTheEngineFailsOnIsLeftOut() async throws {
        let engine = TableEngine([:], failing: [OpeningBook.key(after("e4", "e5"))])
        let book = try await OpeningBook.build(lines: [["e4", "e5", "Nf3"], ["d4"]], plies: 16, marginCp: 50, engine: engine, limits: EngineLimits(depth: 1))
        XCTAssertEqual(book.moves(at: .start).map(\.move), ["d2d4", "e2e4"])
        XCTAssertTrue(book.moves(at: after("e4")).isEmpty, "the move into the failed position is dropped")
        XCTAssertTrue(book.moves(at: after("e4", "e5")).isEmpty)
    }
}
