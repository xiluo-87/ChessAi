import Foundation

public struct Game: Sendable {
    public private(set) var startPosition: Position
    public private(set) var moves: [Move] = []
    public private(set) var sans: [String] = []
    public private(set) var positions: [Position]
    private var resigned: PieceColor?

    public init(start: Position = .start) {
        startPosition = start
        positions = [start]
    }

    public var current: Position { positions[positions.count - 1] }

    public var end: GameEnd? {
        if resigned != nil { return .resignation }
        let p = current
        if p.isCheckmate() { return .checkmate }
        if p.isStalemate() { return .stalemate }
        if p.isInsufficientMaterial() { return .insufficientMaterial }
        if p.halfmoveClock >= 100 { return .fiftyMoveRule }
        let key = p.repetitionKey
        if positions.reduce(0, { $0 + ($1.repetitionKey == key ? 1 : 0) }) >= 3 { return .threefoldRepetition }
        return nil
    }

    public var result: GameResult {
        guard let end else { return .ongoing }
        switch end {
        case .resignation: return resigned == .white ? .blackWins : .whiteWins
        case .checkmate: return current.sideToMove == .white ? .blackWins : .whiteWins
        default: return .draw
        }
    }

    @discardableResult
    public mutating func play(_ move: Move) -> Bool {
        guard end == nil, current.isLegal(move) else { return false }
        let san = current.san(for: move)
        positions.append(current.applying(move))
        moves.append(move)
        sans.append(san)
        return true
    }

    public mutating func resign(_ color: PieceColor) {
        if end == nil { resigned = color }
    }

    public mutating func undo(plies: Int) {
        resigned = nil
        let n = min(max(plies, 0), moves.count)
        moves.removeLast(n)
        sans.removeLast(n)
        positions.removeLast(n)
    }

    public func pgn(tags: [(String, String)]) -> String {
        var out = ""
        for (k, v) in tags {
            let escaped = v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out += "[\(k) \"\(escaped)\"]\n"
        }
        if !tags.isEmpty { out += "\n" }
        var tokens: [String] = []
        var number = startPosition.fullmoveNumber
        var white = startPosition.sideToMove == .white
        for (i, san) in sans.enumerated() {
            if white { tokens.append("\(number).") }
            else if i == 0 { tokens.append("\(number)...") }
            tokens.append(san)
            if !white { number += 1 }
            white.toggle()
        }
        tokens.append(result.rawValue)
        out += tokens.joined(separator: " ") + "\n"
        return out
    }
}
