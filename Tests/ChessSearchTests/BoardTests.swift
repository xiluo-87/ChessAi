import XCTest
import ChessCore
@testable import ChessSearch

/// The search board against ChessCore, whose move generator is the reference.
final class BoardTests: XCTestCase {
    static let positions = [
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    ]

    func corePerft(_ p: Position, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = p.legalMoves()
        if depth == 1 { return moves.count }
        return moves.reduce(0) { $0 + corePerft(p.applying($1), depth - 1) }
    }

    func testPerftAgreesWithChessCore() throws {
        for fen in Self.positions {
            let board = try Board(fen: fen)
            let core = Position(fen: fen)!
            for depth in 1...3 {
                XCTAssertEqual(board.perft(depth), corePerft(core, depth), "\(fen) depth \(depth)")
            }
        }
    }

    /// Published perft counts, one ply deeper than ChessCore's tests reach in reasonable time.
    func testPerftKnownCounts() throws {
        let expected = [197_281, 4_085_603, 43_238, 422_333, 2_103_487]
        for (fen, count) in zip(Self.positions, expected) {
            XCTAssertEqual(try Board(fen: fen).perft(4), count, fen)
        }
    }

    /// Along random games: the same legal moves as ChessCore, a hash that matches one built from the FEN (as
    /// far as repetitions are concerned), and unmake restoring everything.
    func testRandomGamesMatchChessCore() throws {
        var rng = SplitMix(seed: 7)
        let buffer = UnsafeMutablePointer<PackedMove>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        for fen in Self.positions {
            for _ in 0..<8 {
                var position = Position(fen: fen)!
                var played: [String] = []
                for _ in 0..<80 {
                    let legal = position.legalMoves()
                    let board = try Board(fen: fen, moves: played)
                    let n = board.generate(buffer, quiets: true)
                    var ours: [String] = []
                    for i in 0..<n where board.make(buffer[i]) {
                        ours.append(buffer[i].uci)
                        board.unmake()
                    }
                    XCTAssertEqual(Set(ours), Set(legal.map(\.uci)), position.fen)
                    XCTAssertEqual(ours.count, legal.count, position.fen)
                    let fresh = try Board(fen: position.fen)
                    XCTAssertEqual(board.hash, fresh.hash, position.fen)
                    XCTAssertEqual(board.middlegame, fresh.middlegame)
                    XCTAssertEqual(board.endgame, fresh.endgame)
                    XCTAssertEqual(board.phase, fresh.phase)
                    XCTAssertEqual(board.inCheck, position.isInCheck())
                    XCTAssertEqual(board.isInsufficientMaterial, position.isInsufficientMaterial() && Self.isBareMinor(position))
                    guard !legal.isEmpty else { break }
                    let move = legal[Int(rng.next() % UInt64(legal.count))]
                    played.append(move.uci)
                    position = position.applying(move)
                }
            }
        }
    }

    /// The board's rule is narrower than ChessCore's (same-coloured bishops are not a draw here).
    static func isBareMinor(_ p: Position) -> Bool {
        (0..<64).compactMap { p.piece(at: $0) }.filter { $0.kind != .king }.count <= 1
    }

    func testRepetitionNeedsThreeOccurrencesBeforeTheRoot() throws {
        let fen = "7k/8/8/8/8/2K5/8/3Q4 b - - 0 1"
        let cycle = ["h8g8", "d1e1", "g8h8", "e1d1"]
        // Second occurrence: inside a search that would be a draw, from game history alone it is not yet.
        let twice = try Board(fen: fen, moves: cycle)
        XCTAssertFalse(twice.isRepetition(rootPly: twice.ply))
        XCTAssertTrue(twice.isRepetition(rootPly: 0))
        let thrice = try Board(fen: fen, moves: cycle + cycle)
        XCTAssertTrue(thrice.isRepetition(rootPly: thrice.ply))
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try Board(fen: "garbage"))
        XCTAssertThrowsError(try Board(fen: Self.positions[0], moves: ["e2e5"]))
        XCTAssertThrowsError(try Board(fen: Self.positions[0], moves: ["e7e5"]))
    }
}

struct SplitMix {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
