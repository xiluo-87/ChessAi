import Foundation
import ChessCore

/// Piece codes on the search board: the kind (1 pawn ... 6 king) plus 8 for black; 0 is an empty square.
enum Code {
    static let pawn = 1, knight = 2, bishop = 3, rook = 4, queen = 5, king = 6
    static let black = 8
}

/// A move in 16 bits: from (6), to (6), promotion kind (3, 0 for none). Castling and en passant are told apart by
/// the board when the move is made, so the transposition table can store a move as it is.
struct PackedMove: Equatable {
    var raw: UInt16

    static let none = PackedMove(raw: 0)

    init(raw: UInt16) { self.raw = raw }

    init(from: Int, to: Int, promotion: Int = 0) {
        raw = UInt16(truncatingIfNeeded: from | to << 6 | promotion << 12)
    }

    @inline(__always) var from: Int { Int(raw & 63) }
    @inline(__always) var to: Int { Int((raw >> 6) & 63) }
    @inline(__always) var promotion: Int { Int(raw >> 12) }

    var uci: String {
        let promo = ["", "", "n", "b", "r", "q"][promotion]
        return Squares.name(from) + Squares.name(to) + promo
    }
}

/// Precomputed move targets, Zobrist keys and piece-square values, shared by every board.
final class Tables: @unchecked Sendable {
    static let shared = Tables()

    /// Up to 8 targets per square, then the count.
    let knight = UnsafeMutablePointer<Int>.allocate(capacity: 64 * 8)
    let knightCount = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    let king = UnsafeMutablePointer<Int>.allocate(capacity: 64 * 8)
    let kingCount = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    /// Directions 0...3 are orthogonal (rook), 4...7 diagonal (bishop); `rayLength` is the steps to the edge.
    let direction = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    let rayLength = UnsafeMutablePointer<Int>.allocate(capacity: 64 * 8)
    /// Castling rights kept when a move leaves from or lands on a square.
    let castleMask = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    let zPiece = UnsafeMutablePointer<UInt64>.allocate(capacity: 16 * 64)
    let zCastle = UnsafeMutablePointer<UInt64>.allocate(capacity: 16)
    let zEnPassant = UnsafeMutablePointer<UInt64>.allocate(capacity: 8)
    let zSide: UInt64
    /// Material plus placement by piece code and square, positive for White and negative for Black.
    let middlegame = UnsafeMutablePointer<Int>.allocate(capacity: 16 * 64)
    let endgame = UnsafeMutablePointer<Int>.allocate(capacity: 16 * 64)
    let phaseWeight = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    /// Endgame material by kind, for the quiescence search's delta pruning.
    let pieceValue = UnsafeMutablePointer<Int>.allocate(capacity: 8)

    private init() {
        let files = [0, 0, 1, -1, 1, -1, 1, -1], ranks = [1, -1, 0, 0, 1, 1, -1, -1]
        for d in 0..<8 { direction[d] = ranks[d] * 8 + files[d] }
        let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
        for s in 0..<64 {
            let f = s & 7, r = s >> 3
            var n = 0
            for (df, dr) in knightSteps where (0..<8).contains(f + df) && (0..<8).contains(r + dr) {
                knight[s * 8 + n] = (r + dr) * 8 + f + df
                n += 1
            }
            knightCount[s] = n
            n = 0
            for d in 0..<8 where (0..<8).contains(f + files[d]) && (0..<8).contains(r + ranks[d]) {
                king[s * 8 + n] = s + direction[d]
                n += 1
            }
            kingCount[s] = n
            for d in 0..<8 {
                var steps = 0, ff = f + files[d], rr = r + ranks[d]
                while (0..<8).contains(ff) && (0..<8).contains(rr) {
                    steps += 1; ff += files[d]; rr += ranks[d]
                }
                rayLength[s * 8 + d] = steps
            }
            castleMask[s] = 15
        }
        castleMask[0] = 15 & ~2; castleMask[7] = 15 & ~1; castleMask[4] = 15 & ~3
        castleMask[56] = 15 & ~8; castleMask[63] = 15 & ~4; castleMask[60] = 15 & ~12

        // SplitMix64 from a fixed seed: the keys only need to be well mixed and the same on every run.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt64 {
            seed &+= 0x9E37_79B9_7F4A_7C15
            var z = seed
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        for i in 0..<(16 * 64) { zPiece[i] = next() }
        for i in 0..<16 { zCastle[i] = next() }
        for i in 0..<8 { zEnPassant[i] = next() }
        zSide = next()

        for i in 0..<(16 * 64) { middlegame[i] = 0; endgame[i] = 0 }
        for i in 0..<16 { phaseWeight[i] = 0 }
        for kind in 0..<8 { pieceValue[kind] = kind < Evaluation.material.count ? Evaluation.material[kind].eg : 0 }
        for kind in 1...6 {
            for color in 0..<2 {
                let code = kind | color * Code.black
                phaseWeight[code] = Evaluation.phaseWeight[kind]
                for s in 0..<64 {
                    let own = color == 0 ? s : s ^ 56  // the square seen from its owner's side
                    let sign = color == 0 ? 1 : -1
                    middlegame[code * 64 + s] = sign * (Evaluation.material[kind].mg + Evaluation.placement(kind, own, endgame: false))
                    endgame[code * 64 + s] = sign * (Evaluation.material[kind].eg + Evaluation.placement(kind, own, endgame: true))
                }
            }
        }
    }
}

/// What a move changed, so it can be taken back.
struct Undo {
    var move = PackedMove.none
    var captured = 0
    var castling = 0
    var enPassant = -1
    var halfmove = 0
    var hash: UInt64 = 0
    var middlegame = 0
    var endgame = 0
    var phase = 0
}

/// The search's board: a mailbox with make/unmake, an incremental Zobrist hash and incremental piece-square scores.
/// ChessCore's `Position` copies itself on every move, which is right for the app and too slow for a search; this
/// board is checked against it by perft in the tests.
final class Board {
    let t = Tables.shared
    let squares = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    /// Pieces on the board by code, for material checks.
    let counts = UnsafeMutablePointer<Int>.allocate(capacity: 16)
    let kings = UnsafeMutablePointer<Int>.allocate(capacity: 2)
    var side = 0  // 0 White, 1 Black
    var castling = 0  // 1 K, 2 Q, 4 k, 8 q
    /// Set only when a pawn stands ready to take en passant, so equal positions hash alike for repetitions.
    var enPassant = -1
    var halfmove = 0
    var hash: UInt64 = 0
    /// White minus Black, material and placement, kept up to date by every move.
    var middlegame = 0
    var endgame = 0
    var phase = 0

    /// Plies made since the start position, the game's moves first. `hashes[i]` is the hash after `i` plies.
    private(set) var ply = 0
    private let capacity: Int
    private let undo: UnsafeMutablePointer<Undo>
    let hashes: UnsafeMutablePointer<UInt64>

    /// The game so far: `fen` and then `moves` (UCI). Throws for an invalid FEN or an illegal move.
    init(fen: String, moves: [String] = [], searchPlies: Int = 256) throws {
        guard Position(fen: fen) != nil else { throw EngineError.noResponse("invalid FEN: \(fen)") }
        capacity = moves.count + searchPlies + 1
        undo = .allocate(capacity: capacity)
        hashes = .allocate(capacity: capacity)
        for s in 0..<64 { squares[s] = 0 }
        for c in 0..<16 { counts[c] = 0 }
        load(fen)
        hashes[0] = hash
        let buffer = UnsafeMutablePointer<PackedMove>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        for uci in moves {
            guard let m = Move(uci: uci) else { throw EngineError.noResponse("bad move \(uci)") }
            let wanted = PackedMove(from: m.from, to: m.to, promotion: m.promotion.map(Self.code(of:)) ?? 0)
            let n = generate(buffer, quiets: true)
            guard (0..<n).contains(where: { buffer[$0] == wanted }), make(wanted) else {
                throw EngineError.noResponse("illegal move \(uci)")
            }
        }
    }

    deinit {
        squares.deallocate(); counts.deallocate(); kings.deallocate()
        undo.deallocate(); hashes.deallocate()
    }

    static func code(of kind: PieceKind) -> Int {
        switch kind {
        case .pawn: return Code.pawn
        case .knight: return Code.knight
        case .bishop: return Code.bishop
        case .rook: return Code.rook
        case .queen: return Code.queen
        case .king: return Code.king
        }
    }

    /// Plies that may still be made before the history is full.
    var room: Int { capacity - 1 - ply }

    private func load(_ fen: String) {
        let parts = fen.split(separator: " ").map(String.init)
        var s = 56
        for ch in parts[0] {
            if ch == "/" { s -= 16 }
            else if let n = ch.wholeNumberValue { s += n }
            else {
                let kind = ["p": 1, "n": 2, "b": 3, "r": 4, "q": 5, "k": 6][Character(ch.lowercased())]!
                put(kind | (ch.isUppercase ? 0 : Code.black), s)
                if kind == Code.king { kings[ch.isUppercase ? 0 : 1] = s }
                s += 1
            }
        }
        side = parts[1] == "w" ? 0 : 1
        if side == 1 { hash ^= t.zSide }
        for ch in parts[2] {
            switch ch {
            case "K": castling |= 1
            case "Q": castling |= 2
            case "k": castling |= 4
            case "q": castling |= 8
            default: break
            }
        }
        hash ^= t.zCastle[castling]
        if parts[3] != "-", let e = Squares.parse(parts[3]), pawnCanTakeEnPassant(on: e) {
            enPassant = e
            hash ^= t.zEnPassant[e & 7]
        }
        halfmove = parts.count > 4 ? Int(parts[4]) ?? 0 : 0
    }

    private func pawnCanTakeEnPassant(on e: Int) -> Bool {
        let pawn = Code.pawn | side * Code.black
        let from = side == 0 ? e - 8 : e + 8  // where a capturing pawn stands, beside the pawn that moved two
        guard (0..<64).contains(from) else { return false }
        return (e & 7 > 0 && squares[from - 1] == pawn) || (e & 7 < 7 && squares[from + 1] == pawn)
    }

    // MARK: Pieces

    @inline(__always) private func put(_ code: Int, _ s: Int) {
        squares[s] = code
        counts[code] += 1
        hash ^= t.zPiece[code * 64 + s]
        middlegame += t.middlegame[code * 64 + s]
        endgame += t.endgame[code * 64 + s]
        phase += t.phaseWeight[code]
    }

    @inline(__always) private func remove(_ s: Int) {
        let code = squares[s]
        squares[s] = 0
        counts[code] -= 1
        hash ^= t.zPiece[code * 64 + s]
        middlegame -= t.middlegame[code * 64 + s]
        endgame -= t.endgame[code * 64 + s]
        phase -= t.phaseWeight[code]
    }

    /// Unmake restores the hash and scores from its record, so it only moves pieces.
    @inline(__always) private func rawPut(_ code: Int, _ s: Int) {
        squares[s] = code
        counts[code] += 1
    }

    @inline(__always) private func rawRemove(_ s: Int) {
        counts[squares[s]] -= 1
        squares[s] = 0
    }

    // MARK: Attacks

    /// Whether `color` (0 White, 1 Black) attacks square `s`.
    func isAttacked(_ s: Int, by color: Int) -> Bool {
        let f = s & 7
        let them = color * Code.black
        if color == 0 {
            if f < 7 && s >= 7 && squares[s - 7] == Code.pawn { return true }
            if f > 0 && s >= 9 && squares[s - 9] == Code.pawn { return true }
        } else {
            if f > 0 && s + 7 < 64 && squares[s + 7] == Code.pawn | Code.black { return true }
            if f < 7 && s + 9 < 64 && squares[s + 9] == Code.pawn | Code.black { return true }
        }
        let knight = Code.knight | them
        for i in 0..<t.knightCount[s] where squares[t.knight[s * 8 + i]] == knight { return true }
        let king = Code.king | them
        for i in 0..<t.kingCount[s] where squares[t.king[s * 8 + i]] == king { return true }
        let rook = Code.rook | them, bishop = Code.bishop | them, queen = Code.queen | them
        for d in 0..<8 {
            let step = t.direction[d]
            var x = s
            for _ in 0..<t.rayLength[s * 8 + d] {
                x += step
                let p = squares[x]
                if p != 0 {
                    if p == queen || p == (d < 4 ? rook : bishop) { return true }
                    break
                }
            }
        }
        return false
    }

    var inCheck: Bool { isAttacked(kings[side], by: side ^ 1) }

    // MARK: Move generation

    /// Pseudo-legal moves into `out`; `make` rejects those that leave the king in check. Without `quiets`, only
    /// captures and queen promotions, for the quiescence search. Returns the count (at most 218 in any position).
    func generate(_ out: UnsafeMutablePointer<PackedMove>, quiets: Bool) -> Int {
        var n = 0
        let us = side * Code.black
        @inline(__always) func add(_ from: Int, _ to: Int, _ promo: Int = 0) {
            out[n] = PackedMove(from: from, to: to, promotion: promo)
            n += 1
        }
        @inline(__always) func isEnemy(_ p: Int) -> Bool { p != 0 && (p & Code.black) != us }

        let forward = side == 0 ? 8 : -8
        let startRank = side == 0 ? 1 : 6
        let lastRank = side == 0 ? 7 : 0
        for from in 0..<64 {
            let p = squares[from]
            guard p != 0, (p & Code.black) == us else { continue }
            switch p & 7 {
            case Code.pawn:
                let one = from + forward
                let promotes = one >> 3 == lastRank
                if squares[one] == 0 {
                    if promotes {
                        add(from, one, Code.queen)
                        if quiets { add(from, one, Code.rook); add(from, one, Code.bishop); add(from, one, Code.knight) }
                    } else if quiets {
                        add(from, one)
                        if from >> 3 == startRank && squares[one + forward] == 0 { add(from, one + forward) }
                    }
                }
                for df in stride(from: -1, through: 1, by: 2) {
                    let f = (from & 7) + df
                    guard f >= 0 && f < 8 else { continue }
                    let to = one + df
                    guard isEnemy(squares[to]) || to == enPassant else { continue }
                    if promotes {
                        add(from, to, Code.queen)
                        if quiets { add(from, to, Code.rook); add(from, to, Code.bishop); add(from, to, Code.knight) }
                    } else {
                        add(from, to)
                    }
                }
            case Code.knight:
                for i in 0..<t.knightCount[from] {
                    let to = t.knight[from * 8 + i], q = squares[to]
                    if q == 0 ? quiets : isEnemy(q) { add(from, to) }
                }
            case Code.king:
                for i in 0..<t.kingCount[from] {
                    let to = t.king[from * 8 + i], q = squares[to]
                    if q == 0 ? quiets : isEnemy(q) { add(from, to) }
                }
                if quiets && castling != 0 { n = addCastling(out, n, from) }
            default:
                let kind = p & 7
                let first = kind == Code.bishop ? 4 : 0, last = kind == Code.rook ? 4 : 8
                for d in first..<last {
                    let step = t.direction[d]
                    var to = from
                    for _ in 0..<t.rayLength[from * 8 + d] {
                        to += step
                        let q = squares[to]
                        if q == 0 {
                            if quiets { add(from, to) }
                        } else {
                            if isEnemy(q) { add(from, to) }
                            break
                        }
                    }
                }
            }
        }
        return n
    }

    private func addCastling(_ out: UnsafeMutablePointer<PackedMove>, _ count: Int, _ from: Int) -> Int {
        var n = count
        let base = side == 0 ? 0 : 56, them = side ^ 1
        let rook = Code.rook | side * Code.black
        guard from == base + 4, !isAttacked(from, by: them) else { return n }
        let kingSide = side == 0 ? 1 : 4, queenSide = side == 0 ? 2 : 8
        if castling & kingSide != 0, squares[base + 7] == rook, squares[base + 5] == 0, squares[base + 6] == 0,
           !isAttacked(base + 5, by: them), !isAttacked(base + 6, by: them) {
            out[n] = PackedMove(from: from, to: base + 6); n += 1
        }
        if castling & queenSide != 0, squares[base] == rook, squares[base + 1] == 0, squares[base + 2] == 0,
           squares[base + 3] == 0, !isAttacked(base + 3, by: them), !isAttacked(base + 2, by: them) {
            out[n] = PackedMove(from: from, to: base + 2); n += 1
        }
        return n
    }

    // MARK: Making moves

    /// Makes a pseudo-legal move. Returns false, with the board unchanged, if it leaves the mover's king in check.
    @discardableResult
    func make(_ m: PackedMove) -> Bool {
        let from = m.from, to = m.to, promo = m.promotion
        let piece = squares[from], kind = piece & 7
        undo[ply] = Undo(
            move: m, captured: squares[to], castling: castling, enPassant: enPassant, halfmove: halfmove, hash: hash,
            middlegame: middlegame, endgame: endgame, phase: phase)
        if enPassant >= 0 { hash ^= t.zEnPassant[enPassant & 7] }
        hash ^= t.zCastle[castling]
        halfmove += 1
        if squares[to] != 0 {
            remove(to)
            halfmove = 0
        }
        var newEnPassant = -1
        if kind == Code.pawn {
            halfmove = 0
            if to == enPassant {
                let taken = side == 0 ? to - 8 : to + 8
                undo[ply].captured = squares[taken]
                remove(taken)
            }
        }
        remove(from)
        put(promo != 0 ? promo | side * Code.black : piece, to)
        if kind == Code.king {
            kings[side] = to
            if to - from == 2 {
                remove(to + 1); put(Code.rook | side * Code.black, to - 1)
            } else if from - to == 2 {
                remove(to - 2); put(Code.rook | side * Code.black, to + 1)
            }
        }
        castling &= t.castleMask[from] & t.castleMask[to]
        hash ^= t.zCastle[castling]
        side ^= 1
        hash ^= t.zSide
        if kind == Code.pawn && (to - from == 16 || from - to == 16) && pawnCanTakeEnPassant(on: (from + to) / 2) {
            newEnPassant = (from + to) / 2
            hash ^= t.zEnPassant[newEnPassant & 7]
        }
        enPassant = newEnPassant
        ply += 1
        hashes[ply] = hash
        if isAttacked(kings[side ^ 1], by: side) {
            unmake()
            return false
        }
        return true
    }

    func unmake() {
        ply -= 1
        let u = undo[ply]
        side ^= 1
        let from = u.move.from, to = u.move.to
        let moved = squares[to]
        let original = u.move.promotion != 0 ? Code.pawn | side * Code.black : moved
        rawRemove(to)
        rawPut(original, from)
        let kind = original & 7
        if kind == Code.king {
            kings[side] = from
            if to - from == 2 {
                rawRemove(to - 1); rawPut(Code.rook | side * Code.black, to + 1)
            } else if from - to == 2 {
                rawRemove(to + 1); rawPut(Code.rook | side * Code.black, to - 2)
            }
        }
        if kind == Code.pawn && to == u.enPassant {
            rawPut(u.captured, side == 0 ? to - 8 : to + 8)
        } else if u.captured != 0 {
            rawPut(u.captured, to)
        }
        castling = u.castling
        enPassant = u.enPassant
        halfmove = u.halfmove
        hash = u.hash
        middlegame = u.middlegame
        endgame = u.endgame
        phase = u.phase
    }

    /// Passes the move, for null-move pruning.
    func makeNull() {
        undo[ply] = Undo(
            move: .none, captured: 0, castling: castling, enPassant: enPassant, halfmove: halfmove, hash: hash,
            middlegame: middlegame, endgame: endgame, phase: phase)
        if enPassant >= 0 { hash ^= t.zEnPassant[enPassant & 7] }
        enPassant = -1
        side ^= 1
        hash ^= t.zSide
        halfmove += 1
        ply += 1
        hashes[ply] = hash
    }

    func unmakeNull() {
        ply -= 1
        let u = undo[ply]
        side ^= 1
        enPassant = u.enPassant
        halfmove = u.halfmove
        hash = u.hash
    }

    // MARK: Draws and material

    /// Whether the position after `ply` plies repeats: once if the earlier one is at or after `rootPly` (inside the
    /// search), twice if both are in the game before it, which is the game's own threefold repetition.
    func isRepetition(rootPly: Int) -> Bool {
        let key = hash
        var seen = 0
        var i = ply - 4
        let oldest = max(0, ply - halfmove)
        while i >= oldest {
            if hashes[i] == key {
                if i >= rootPly { return true }
                seen += 1
                if seen >= 2 { return true }
            }
            i -= 2
        }
        return false
    }

    /// No pawns, rooks or queens, and at most one minor piece: neither side can mate.
    var isInsufficientMaterial: Bool {
        let heavy = counts[Code.pawn] + counts[Code.rook] + counts[Code.queen]
            + counts[Code.pawn | Code.black] + counts[Code.rook | Code.black] + counts[Code.queen | Code.black]
        let minors = counts[Code.knight] + counts[Code.bishop] + counts[Code.knight | Code.black] + counts[Code.bishop | Code.black]
        return heavy == 0 && minors <= 1
    }

    /// Whether the side to move has a piece besides pawns and king: null-move pruning is unsafe without one.
    var hasPieces: Bool {
        let c = side * Code.black
        return counts[Code.knight | c] + counts[Code.bishop | c] + counts[Code.rook | c] + counts[Code.queen | c] > 0
    }

    // MARK: Perft

    func perft(_ depth: Int) -> Int {
        let buffer = UnsafeMutablePointer<PackedMove>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        let n = generate(buffer, quiets: true)
        var total = 0
        for i in 0..<n where make(buffer[i]) {
            total += depth <= 1 ? 1 : perft(depth - 1)
            unmake()
        }
        return total
    }
}
