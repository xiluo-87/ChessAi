import Foundation

struct CastlingRights: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let whiteKing = CastlingRights(rawValue: 1)
    static let whiteQueen = CastlingRights(rawValue: 2)
    static let blackKing = CastlingRights(rawValue: 4)
    static let blackQueen = CastlingRights(rawValue: 8)
}

public struct Position: Hashable, Sendable {
    private var board: [Piece?]
    public private(set) var sideToMove: PieceColor
    private var castling: CastlingRights
    public private(set) var enPassant: Square?
    public private(set) var halfmoveClock: Int
    public private(set) var fullmoveNumber: Int

    public static let start = Position(
        fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")!

    // MARK: FEN

    public init?(fen: String) {
        let parts = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 4 else { return nil }
        var board = [Piece?](repeating: nil, count: 64)
        let rows = parts[0].split(separator: "/", omittingEmptySubsequences: false)
        guard rows.count == 8 else { return nil }
        for (i, row) in rows.enumerated() {
            let rank = 7 - i
            var file = 0
            for ch in row {
                if let n = ch.wholeNumberValue, ch != "0", ch != "9" {
                    file += n
                } else if let p = Piece(fenChar: ch) {
                    guard file < 8 else { return nil }
                    board[Squares.make(file: file, rank: rank)] = p
                    file += 1
                } else { return nil }
            }
            guard file == 8 else { return nil }
        }
        guard parts[1] == "w" || parts[1] == "b" else { return nil }
        var rights: CastlingRights = []
        if parts[2] != "-" {
            for ch in parts[2] {
                switch ch {
                case "K": rights.insert(.whiteKing)
                case "Q": rights.insert(.whiteQueen)
                case "k": rights.insert(.blackKing)
                case "q": rights.insert(.blackQueen)
                default: return nil
                }
            }
        }
        var ep: Square?
        if parts[3] != "-" {
            guard let s = Squares.parse(parts[3]) else { return nil }
            ep = s
        }
        let half = parts.count > 4 ? Int(parts[4]) : 0
        let full = parts.count > 5 ? Int(parts[5]) : 1
        guard let half, let full, half >= 0, full >= 1 else { return nil }
        for color in PieceColor.allCases {
            guard board.filter({ $0 == Piece(.king, color) }).count == 1 else { return nil }
        }
        self.board = board
        self.sideToMove = parts[1] == "w" ? .white : .black
        self.castling = rights
        self.enPassant = ep
        self.halfmoveClock = half
        self.fullmoveNumber = full
    }

    private func fenPrefix(includeEnPassantAlways: Bool) -> String {
        var rows: [String] = []
        for rank in stride(from: 7, through: 0, by: -1) {
            var row = ""
            var empty = 0
            for file in 0..<8 {
                if let p = board[Squares.make(file: file, rank: rank)] {
                    if empty > 0 { row += String(empty); empty = 0 }
                    row.append(p.fenChar)
                } else { empty += 1 }
            }
            if empty > 0 { row += String(empty) }
            rows.append(row)
        }
        var c = ""
        if castling.contains(.whiteKing) { c += "K" }
        if castling.contains(.whiteQueen) { c += "Q" }
        if castling.contains(.blackKing) { c += "k" }
        if castling.contains(.blackQueen) { c += "q" }
        if c.isEmpty { c = "-" }
        var ep = "-"
        if let e = enPassant {
            if includeEnPassantAlways || enPassantCaptureExists(e) { ep = Squares.name(e) }
        }
        return "\(rows.joined(separator: "/")) \(sideToMove == .white ? "w" : "b") \(c) \(ep)"
    }

    public var fen: String {
        fenPrefix(includeEnPassantAlways: true) + " \(halfmoveClock) \(fullmoveNumber)"
    }

    /// FEN without clocks; the en passant square is kept only if a legal en passant capture exists.
    public var repetitionKey: String {
        fenPrefix(includeEnPassantAlways: false)
    }

    private func enPassantCaptureExists(_ e: Square) -> Bool {
        legalMoves().contains { m in
            m.to == e && board[m.from]?.kind == .pawn
        }
    }

    // MARK: Queries

    public func piece(at s: Square) -> Piece? { board[s] }

    public func material(for color: PieceColor) -> Int {
        board.reduce(0) { $0 + (($1?.color == color) ? $1!.kind.value : 0) }
    }

    private func kingSquare(_ color: PieceColor) -> Square {
        board.firstIndex(of: Piece(.king, color))!
    }

    private static let knightDeltas = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingDeltas = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookDirs = [(1, 0), (0, 1), (-1, 0), (0, -1)]
    private static let bishopDirs = [(1, 1), (-1, 1), (-1, -1), (1, -1)]

    private func isAttacked(_ sq: Square, by color: PieceColor) -> Bool {
        let f = Squares.file(sq), r = Squares.rank(sq)
        // pawns: an attacking pawn sits one rank behind the target (from its own view)
        let pr = color == .white ? r - 1 : r + 1
        if (0..<8).contains(pr) {
            for df in [-1, 1] where (0..<8).contains(f + df) {
                if board[Squares.make(file: f + df, rank: pr)] == Piece(.pawn, color) { return true }
            }
        }
        for (df, dr) in Self.knightDeltas {
            let nf = f + df, nr = r + dr
            if (0..<8).contains(nf), (0..<8).contains(nr),
               board[Squares.make(file: nf, rank: nr)] == Piece(.knight, color) { return true }
        }
        for (df, dr) in Self.kingDeltas {
            let nf = f + df, nr = r + dr
            if (0..<8).contains(nf), (0..<8).contains(nr),
               board[Squares.make(file: nf, rank: nr)] == Piece(.king, color) { return true }
        }
        for (dirs, kinds) in [(Self.rookDirs, [PieceKind.rook, .queen]), (Self.bishopDirs, [PieceKind.bishop, .queen])] {
            for (df, dr) in dirs {
                var nf = f + df, nr = r + dr
                while (0..<8).contains(nf), (0..<8).contains(nr) {
                    if let p = board[Squares.make(file: nf, rank: nr)] {
                        if p.color == color, kinds.contains(p.kind) { return true }
                        break
                    }
                    nf += df; nr += dr
                }
            }
        }
        return false
    }

    public func isInCheck() -> Bool {
        isAttacked(kingSquare(sideToMove), by: sideToMove.opposite)
    }

    // MARK: Move generation

    private func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        let us = sideToMove
        for from in 0..<64 {
            guard let p = board[from], p.color == us else { continue }
            let f = Squares.file(from), r = Squares.rank(from)
            switch p.kind {
            case .pawn:
                let dir = us == .white ? 1 : -1
                let startRank = us == .white ? 1 : 6
                let lastRank = us == .white ? 7 : 0
                func add(_ to: Square) {
                    if Squares.rank(to) == lastRank {
                        for k in [PieceKind.queen, .rook, .bishop, .knight] {
                            moves.append(Move(from: from, to: to, promotion: k))
                        }
                    } else { moves.append(Move(from: from, to: to)) }
                }
                let nr = r + dir
                guard (0..<8).contains(nr) else { continue }
                let one = Squares.make(file: f, rank: nr)
                if board[one] == nil {
                    add(one)
                    if r == startRank {
                        let two = Squares.make(file: f, rank: nr + dir)
                        if board[two] == nil { moves.append(Move(from: from, to: two)) }
                    }
                }
                for df in [-1, 1] where (0..<8).contains(f + df) {
                    let to = Squares.make(file: f + df, rank: nr)
                    if let t = board[to], t.color != us { add(to) }
                    else if board[to] == nil, to == enPassant { add(to) }
                }
            case .knight, .king:
                let deltas = p.kind == .knight ? Self.knightDeltas : Self.kingDeltas
                for (df, dr) in deltas {
                    let nf = f + df, nr = r + dr
                    guard (0..<8).contains(nf), (0..<8).contains(nr) else { continue }
                    let to = Squares.make(file: nf, rank: nr)
                    if board[to]?.color != us { moves.append(Move(from: from, to: to)) }
                }
            case .bishop, .rook, .queen:
                var dirs: [(Int, Int)] = []
                if p.kind != .bishop { dirs += Self.rookDirs }
                if p.kind != .rook { dirs += Self.bishopDirs }
                for (df, dr) in dirs {
                    var nf = f + df, nr = r + dr
                    while (0..<8).contains(nf), (0..<8).contains(nr) {
                        let to = Squares.make(file: nf, rank: nr)
                        if let t = board[to] {
                            if t.color != us { moves.append(Move(from: from, to: to)) }
                            break
                        }
                        moves.append(Move(from: from, to: to))
                        nf += df; nr += dr
                    }
                }
            }
        }
        moves += castlingMoves()
        return moves
    }

    private func castlingMoves() -> [Move] {
        let us = sideToMove, them = us.opposite
        let base = us == .white ? 0 : 56
        guard board[base + 4] == Piece(.king, us) else { return [] }
        let kRight: CastlingRights = us == .white ? .whiteKing : .blackKing
        let qRight: CastlingRights = us == .white ? .whiteQueen : .blackQueen
        guard castling.contains(kRight) || castling.contains(qRight) else { return [] }
        guard !isAttacked(base + 4, by: them) else { return [] }
        var result: [Move] = []
        if castling.contains(kRight), board[base + 7] == Piece(.rook, us),
           board[base + 5] == nil, board[base + 6] == nil,
           !isAttacked(base + 5, by: them), !isAttacked(base + 6, by: them) {
            result.append(Move(from: base + 4, to: base + 6))
        }
        if castling.contains(qRight), board[base] == Piece(.rook, us),
           board[base + 1] == nil, board[base + 2] == nil, board[base + 3] == nil,
           !isAttacked(base + 3, by: them), !isAttacked(base + 2, by: them) {
            result.append(Move(from: base + 4, to: base + 2))
        }
        return result
    }

    public func legalMoves() -> [Move] {
        let us = sideToMove
        return pseudoLegalMoves().filter { m in
            let next = makeMove(m)
            return !next.isAttacked(next.kingSquare(us), by: us.opposite)
        }
    }

    public func legalMoves(from s: Square) -> [Move] {
        legalMoves().filter { $0.from == s }
    }

    public func isLegal(_ move: Move) -> Bool {
        legalMoves().contains(move)
    }

    // MARK: Making moves

    public func applying(_ move: Move) -> Position {
        precondition(isLegal(move), "Illegal move \(move.uci) in \(fen)")
        return makeMove(move)
    }

    private func makeMove(_ m: Move) -> Position {
        var p = self
        let piece = board[m.from]!
        let isCapture = board[m.to] != nil
        p.board[m.from] = nil
        p.board[m.to] = m.promotion.map { Piece($0, piece.color) } ?? piece
        p.enPassant = nil
        if piece.kind == .pawn {
            if m.to == enPassant, !isCapture, Squares.file(m.from) != Squares.file(m.to) {
                // en passant: captured pawn sits on the mover's origin rank
                p.board[Squares.make(file: Squares.file(m.to), rank: Squares.rank(m.from))] = nil
            }
            if abs(Squares.rank(m.to) - Squares.rank(m.from)) == 2 {
                p.enPassant = (m.from + m.to) / 2
            }
        } else if piece.kind == .king, abs(Squares.file(m.to) - Squares.file(m.from)) == 2 {
            let base = Squares.rank(m.from) * 8
            if Squares.file(m.to) == 6 {
                p.board[base + 7] = nil; p.board[base + 5] = Piece(.rook, piece.color)
            } else {
                p.board[base] = nil; p.board[base + 3] = Piece(.rook, piece.color)
            }
        }
        for sq in [m.from, m.to] {
            switch sq {
            case 0: p.castling.remove(.whiteQueen)
            case 7: p.castling.remove(.whiteKing)
            case 56: p.castling.remove(.blackQueen)
            case 63: p.castling.remove(.blackKing)
            case 4: p.castling.subtract([.whiteKing, .whiteQueen])
            case 60: p.castling.subtract([.blackKing, .blackQueen])
            default: break
            }
        }
        p.halfmoveClock = (piece.kind == .pawn || isCapture || p.board.compactMap { $0 }.count != board.compactMap { $0 }.count) ? 0 : halfmoveClock + 1
        if sideToMove == .black { p.fullmoveNumber += 1 }
        p.sideToMove = sideToMove.opposite
        return p
    }

    // MARK: Game state

    public func isCheckmate() -> Bool { isInCheck() && legalMoves().isEmpty }
    public func isStalemate() -> Bool { !isInCheck() && legalMoves().isEmpty }

    public func isInsufficientMaterial() -> Bool {
        var minors: [(PieceKind, Square)] = []
        for (sq, p) in board.enumerated() {
            guard let p else { continue }
            switch p.kind {
            case .king: continue
            case .knight, .bishop: minors.append((p.kind, sq))
            default: return false
            }
        }
        if minors.count <= 1 { return true }
        guard minors.allSatisfy({ $0.0 == .bishop }) else { return false }
        let shades = Set(minors.map { (Squares.file($0.1) + Squares.rank($0.1)) & 1 })
        return shades.count == 1
    }

    // MARK: SAN

    public func san(for move: Move) -> String {
        guard let piece = board[move.from] else { return move.uci }
        var s = ""
        if piece.kind == .king, abs(Squares.file(move.to) - Squares.file(move.from)) == 2 {
            s = Squares.file(move.to) == 6 ? "O-O" : "O-O-O"
        } else {
            let isCapture = board[move.to] != nil || (piece.kind == .pawn && Squares.file(move.from) != Squares.file(move.to))
            if piece.kind == .pawn {
                if isCapture { s += String(Squares.name(move.from).first!) }
            } else {
                s += piece.kind.rawValue.uppercased()
                let others = legalMoves().filter {
                    $0.to == move.to && $0.from != move.from && board[$0.from]?.kind == piece.kind
                }
                if !others.isEmpty {
                    let sameFile = others.contains { Squares.file($0.from) == Squares.file(move.from) }
                    let sameRank = others.contains { Squares.rank($0.from) == Squares.rank(move.from) }
                    let name = Squares.name(move.from)
                    if !sameFile { s += String(name.first!) }
                    else if !sameRank { s += String(name.last!) }
                    else { s += name }
                }
            }
            if isCapture { s += "x" }
            s += Squares.name(move.to)
            if let promo = move.promotion { s += "=" + promo.rawValue.uppercased() }
        }
        let next = makeMove(move)
        if next.isInCheck() {
            s += next.legalMoves().isEmpty ? "#" : "+"
        }
        return s
    }

    public func move(fromSAN text: String) -> Move? {
        func normalize(_ t: String) -> String {
            var t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.replacingOccurrences(of: "0", with: "O")
            t = t.replacingOccurrences(of: "e.p.", with: "")
            return t.filter { !"+#!?x=:-_ ".contains($0) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = Move(uci: trimmed), isLegal(m) { return m }
        let target = normalize(trimmed)
        guard !target.isEmpty else { return nil }
        let legal = legalMoves()
        if let m = legal.first(where: { normalize(san(for: $0)) == target }) { return m }
        // Tolerate missing disambiguation-free forms such as "Pe4" or lowercase piece letters.
        if target.first == "P" {
            let rest = String(target.dropFirst())
            return legal.first { normalize(san(for: $0)) == rest }
        }
        return nil
    }
}
