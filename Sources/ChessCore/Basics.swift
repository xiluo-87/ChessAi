import Foundation

public enum PieceColor: String, Codable, Sendable, CaseIterable {
    case white, black
    public var opposite: PieceColor { self == .white ? .black : .white }
}

public enum PieceKind: String, Codable, Sendable, CaseIterable {
    case pawn = "p", knight = "n", bishop = "b", rook = "r", queen = "q", king = "k"

    public var value: Int {
        switch self {
        case .pawn: return 1
        case .knight, .bishop: return 3
        case .rook: return 5
        case .queen: return 9
        case .king: return 0
        }
    }
}

public struct Piece: Hashable, Codable, Sendable {
    public let kind: PieceKind
    public let color: PieceColor

    public init(_ kind: PieceKind, _ color: PieceColor) {
        self.kind = kind
        self.color = color
    }

    public var fenChar: Character {
        let c = Character(kind.rawValue)
        return color == .white ? Character(c.uppercased()) : c
    }

    public var symbol: String {
        switch kind {
        case .king: return "\u{265A}"
        case .queen: return "\u{265B}"
        case .rook: return "\u{265C}"
        case .bishop: return "\u{265D}"
        case .knight: return "\u{265E}"
        case .pawn: return "\u{265F}\u{FE0E}"  // text presentation, not emoji
        }
    }

    init?(fenChar c: Character) {
        guard let kind = PieceKind(rawValue: c.lowercased()) else { return nil }
        self.init(kind, c.isUppercase ? .white : .black)
    }
}

public typealias Square = Int

public enum Squares {
    public static func file(_ s: Square) -> Int { s & 7 }
    public static func rank(_ s: Square) -> Int { s >> 3 }
    public static func make(file: Int, rank: Int) -> Square { rank * 8 + file }

    public static func name(_ s: Square) -> String {
        let f = Character(UnicodeScalar(UInt8(97 + file(s))))
        return "\(f)\(rank(s) + 1)"
    }

    public static func parse(_ s: String) -> Square? {
        let u = Array(s.utf8)
        guard u.count == 2, u[0] >= 97, u[0] <= 104, u[1] >= 49, u[1] <= 56 else { return nil }
        return make(file: Int(u[0]) - 97, rank: Int(u[1]) - 49)
    }
}

public struct Move: Hashable, Codable, Sendable {
    public let from: Square
    public let to: Square
    public let promotion: PieceKind?

    public init(from: Square, to: Square, promotion: PieceKind? = nil) {
        self.from = from
        self.to = to
        self.promotion = promotion
    }

    public init?(uci: String) {
        let t = uci.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.count == 4 || t.count == 5 else { return nil }
        guard let f = Squares.parse(String(t.prefix(2))),
              let to = Squares.parse(String(t.dropFirst(2).prefix(2))) else { return nil }
        var promo: PieceKind?
        if t.count == 5 {
            guard let k = PieceKind(rawValue: String(t.last!)),
                  [.knight, .bishop, .rook, .queen].contains(k) else { return nil }
            promo = k
        }
        self.init(from: f, to: to, promotion: promo)
    }

    public var uci: String {
        Squares.name(from) + Squares.name(to) + (promotion?.rawValue ?? "")
    }
}

public enum GameResult: String, Codable, Sendable {
    case whiteWins = "1-0", blackWins = "0-1", draw = "1/2-1/2", ongoing = "*"
}

public enum GameEnd: String, Codable, Sendable {
    case checkmate, stalemate, fiftyMoveRule, threefoldRepetition, insufficientMaterial, resignation
}
