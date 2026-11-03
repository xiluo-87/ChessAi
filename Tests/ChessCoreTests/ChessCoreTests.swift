import XCTest
@testable import ChessCore

final class ChessCoreTests: XCTestCase {
    func perft(_ p: Position, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = p.legalMoves()
        if depth == 1 { return moves.count }
        return moves.reduce(0) { $0 + perft(p.applying($1), depth - 1) }
    }

    static let kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"

    func testPerftStart() {
        for (d, n) in [(1, 20), (2, 400), (3, 8902), (4, 197281)] {
            XCTAssertEqual(perft(.start, d), n, "depth \(d)")
        }
    }

    func testPerftKiwipete() {
        let p = Position(fen: Self.kiwipete)!
        for (d, n) in [(1, 48), (2, 2039), (3, 97862)] {
            XCTAssertEqual(perft(p, d), n, "depth \(d)")
        }
    }

    func testPerftPosition3() {
        let p = Position(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")!
        for (d, n) in [(1, 14), (2, 191), (3, 2812), (4, 43238)] {
            XCTAssertEqual(perft(p, d), n, "depth \(d)")
        }
    }

    func testFenRoundTrip() {
        XCTAssertEqual(Position.start.fen, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
        for f in [Self.kiwipete, "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
                  "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"] {
            XCTAssertEqual(Position(fen: f)!.fen, f)
        }
        XCTAssertNil(Position(fen: "garbage"))
    }

    func testSquaresAndMoves() {
        XCTAssertEqual(Squares.name(0), "a1")
        XCTAssertEqual(Squares.parse("h8"), 63)
        XCTAssertNil(Squares.parse("i1"))
        XCTAssertEqual(Move(uci: "e7e8q")?.promotion, .queen)
        XCTAssertEqual(Move(uci: "e2e4")?.uci, "e2e4")
    }

    func sanOf(_ fen: String, _ uci: String) -> String {
        let p = Position(fen: fen)!
        return p.san(for: Move(uci: uci)!)
    }

    func testSAN() {
        XCTAssertEqual(sanOf("4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1", "b1d2"), "Nbd2")
        XCTAssertEqual(sanOf("4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1", "f3d2"), "Nfd2")
        XCTAssertEqual(sanOf("7k/8/8/R7/8/8/8/R5K1 w - - 0 1", "a1a3"), "R1a3")
        XCTAssertEqual(sanOf("7k/8/8/R7/8/8/8/R5K1 w - - 0 1", "a5a3"), "R5a3")
        XCTAssertEqual(sanOf("k7/4P3/8/8/8/8/8/4K3 w - - 0 1", "e7e8q"), "e8=Q+")
        XCTAssertEqual(sanOf("6k1/5ppp/8/8/8/8/8/R3K3 w - - 0 1", "a1a8"), "Ra8#")
        let c = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        XCTAssertEqual(sanOf(c, "e1g1"), "O-O")
        XCTAssertEqual(sanOf(c, "e1c1"), "O-O-O")
        XCTAssertEqual(sanOf(Self.kiwipete, "e5f7"), "Nxf7")
        XCTAssertEqual(sanOf("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3", "e5d6"), "exd6")
    }

    func testFromSAN() {
        let p = Position(fen: Self.kiwipete)!
        for m in p.legalMoves() {
            XCTAssertEqual(p.move(fromSAN: p.san(for: m)), m, p.san(for: m))
            XCTAssertEqual(p.move(fromSAN: m.uci), m)
        }
        XCTAssertEqual(p.move(fromSAN: "0-0")?.uci, "e1g1")
        XCTAssertEqual(p.move(fromSAN: "Nxf7+!?")?.uci, "e5f7")
        XCTAssertNil(p.move(fromSAN: "Qa8"))
    }

    func testPinnedEnPassant() {
        // Capturing en passant would expose the white king on a5 to the rook on h5.
        let p = Position(fen: "8/8/8/K2pP2r/8/8/8/7k w - d6 0 1")!
        XCTAssertFalse(p.legalMoves().contains(Move(uci: "e5d6")!))
    }

    func testCastlingRules() {
        // Rook on f8 attacks f1: no kingside castling; queenside fine.
        let p = Position(fen: "5r1k/8/8/8/8/8/8/R3K2R w KQ - 0 1")!
        let ucis = p.legalMoves().map(\.uci)
        XCTAssertFalse(ucis.contains("e1g1"))
        XCTAssertTrue(ucis.contains("e1c1"))
        // Capturing a rook removes the right.
        let q = Position(fen: "r3k2r/8/8/8/8/8/6B1/R3K2R w KQkq - 0 1")!
        // Bg2 isn't capturing; use direct rook capture instead.
        let r = Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")!.applying(Move(uci: "a1a8")!)
        XCTAssertFalse(r.fen.split(separator: " ")[2].contains("q"))
        XCTAssertFalse(r.fen.split(separator: " ")[2].contains("Q"))
        _ = q
    }

    func testFoolsMate() {
        var g = Game()
        for u in ["f2f3", "e7e5", "g2g4", "d8h4"] { XCTAssertTrue(g.play(Move(uci: u)!)) }
        XCTAssertEqual(g.end, .checkmate)
        XCTAssertEqual(g.result, .blackWins)
        XCTAssertFalse(g.play(Move(uci: "a2a3")!))
        XCTAssertEqual(g.sans, ["f3", "e5", "g4", "Qh4#"])
        let pgn = g.pgn(tags: [("Event", "Test"), ("White", "A"), ("Black", "B")])
        XCTAssertTrue(pgn.contains("[Event \"Test\"]"))
        XCTAssertTrue(pgn.contains("1. f3 e5 2. g4 Qh4# 0-1"))
        g.undo(plies: 1)
        XCTAssertEqual(g.result, .ongoing)
        XCTAssertEqual(g.positions.count, g.moves.count + 1)
    }

    func testThreefold() {
        var g = Game()
        for u in ["g1f3", "g8f6", "f3g1", "f6g8", "g1f3", "g8f6", "f3g1", "f6g8"] {
            XCTAssertNil(g.end)
            XCTAssertTrue(g.play(Move(uci: u)!))
        }
        XCTAssertEqual(g.end, .threefoldRepetition)
        XCTAssertEqual(g.result, .draw)
    }

    func testResignAndDraws() {
        var g = Game()
        g.resign(.white)
        XCTAssertEqual(g.result, .blackWins)
        g.undo(plies: 0)
        XCTAssertEqual(g.result, .ongoing)
        XCTAssertTrue(Position(fen: "4k3/8/8/8/8/8/8/4K1N1 w - - 0 1")!.isInsufficientMaterial())
        XCTAssertTrue(Position(fen: "4kb2/8/8/8/8/8/8/2B1K3 w - - 0 1")!.isInsufficientMaterial())
        XCTAssertFalse(Position(fen: "4k3/8/8/8/8/8/P7/4K3 w - - 0 1")!.isInsufficientMaterial())
        XCTAssertTrue(Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")!.isStalemate())
        let fifty = Game(start: Position(fen: "4k3/8/8/8/8/8/R7/4K3 w - - 99 80")!)
        var g2 = fifty
        g2.play(Move(uci: "a2a3")!)
        XCTAssertEqual(g2.end, .fiftyMoveRule)
    }
}
