import Foundation
import ChessCore
import ChessEngine

public enum GamePhase: String, Codable, Sendable, CaseIterable {
    case opening, middlegame, endgame

    static func of(_ position: Position, ply: Int) -> GamePhase {
        // Queens, rooks and minors of both sides; pawns and kings do not count.
        let pieces = PieceColor.allCases.reduce(0) { sum, color in
            sum + position.material(for: color) - pawnCount(position, color)
        }
        if pieces <= 14 { return .endgame }
        return ply < 20 ? .opening : .middlegame
    }

    private static func pawnCount(_ position: Position, _ color: PieceColor) -> Int {
        (0..<64).filter { position.piece(at: $0) == Piece(.pawn, color) }.count
    }
}

public enum Judgement: String, Codable, Sendable {
    case best, good, inaccuracy, mistake, blunder

    static func of(loss: Int, best: Bool) -> Judgement {
        if best { return .best }
        switch loss {
        case ..<50: return .good
        case ..<100: return .inaccuracy
        case ..<300: return .mistake
        default: return .blunder
        }
    }
}

public struct PlyReview: Codable, Sendable, Hashable {
    public var ply: Int
    public var san: String
    public var byPersona: Bool
    public var bestSAN: String
    /// From White's side, in centipawns (mates mapped to large values).
    public var evalBefore: Int
    public var evalAfter: Int
    /// What the move cost its player, in centipawns, never negative, capped at 1000.
    public var loss: Int
    public var judgement: Judgement
    public var phase: GamePhase

    /// "12. Nf3? (best Bxf7+, −1.8)"
    public var label: String {
        let number = ply / 2 + 1
        let mark = [Judgement.inaccuracy: "?!", .mistake: "?", .blunder: "??"][judgement] ?? ""
        return "\(number)\(ply % 2 == 0 ? "." : "...") \(san)\(mark) (best \(bestSAN), -\(String(format: "%.1f", Double(loss) / 100)))"
    }
}

/// Facts about one side's play in one game, all computed locally: these are what the cheap model turns into notes.
public struct SideStats: Codable, Sendable, Hashable {
    public var moves = 0
    public var averageLoss = 0
    public var inaccuracies = 0, mistakes = 0, blunders = 0
    public var lossByPhase: [GamePhase: Int] = [:]
    public var castled: String = "never"
    public var queenMovesBeforeMove10 = 0
    public var captures = 0
    public var checks = 0
    public var pawnMoveShare = 0
    public var openingLine: [String] = []

    public var text: String {
        let phases = GamePhase.allCases.compactMap { p in lossByPhase[p].map { "\(p.rawValue) \($0)" } }.joined(separator: ", ")
        return "moves \(moves), avg loss \(averageLoss) cp (\(phases)), inaccuracies \(inaccuracies), mistakes \(mistakes), "
            + "blunders \(blunders), castled \(castled), early queen moves \(queenMovesBeforeMove10), captures \(captures), "
            + "checks \(checks), pawn moves \(pawnMoveShare)%, opening: \(openingLine.joined(separator: " "))"
    }
}

public struct GameReview: Codable, Sendable, Hashable {
    public var plies: [PlyReview]
    public var persona: SideStats
    public var opponent: SideStats

    /// The costliest moves of one side, worst first.
    public func critical(byPersona: Bool, limit: Int = 4) -> [PlyReview] {
        plies.filter { $0.byPersona == byPersona && $0.loss >= 50 }.sorted { $0.loss > $1.loss }.prefix(limit).map { $0 }
    }
}

/// The post-game engine pass: free, local, and the only input the memory update needs besides the move notes.
public struct GameReviewer: Sendable {
    public var engine: StockfishEngine
    public var depth: Int

    public init(engine: StockfishEngine, depth: Int = 12) {
        self.engine = engine
        self.depth = depth
    }

    public func review(_ game: Game, personaColor: PieceColor) async throws -> GameReview {
        // One evaluation per position, from White's side, with the best move there.
        var evals: [Int] = []
        var bests: [Move?] = []
        for position in game.positions {
            if position.legalMoves().isEmpty {
                evals.append(position.isCheckmate() ? (position.sideToMove == .white ? -100_000 : 100_000) : 0)
                bests.append(nil)
                continue
            }
            let line = try await engine.analyse(fen: position.fen, multiPV: 1, limits: EngineLimits(depth: depth)).first
            let score = line?.score.normalized ?? 0
            evals.append(position.sideToMove == .white ? score : -score)
            bests.append(line.flatMap { Move(uci: $0.move) })
        }

        var plies: [PlyReview] = []
        for (ply, move) in game.moves.enumerated() {
            let before = game.positions[ply]
            let mover = before.sideToMove
            let sign = mover == .white ? 1 : -1
            let cappedBefore = max(-1_000, min(1_000, evals[ply]))
            let cappedAfter = max(-1_000, min(1_000, evals[ply + 1]))
            let loss = max(0, min(1_000, (cappedBefore - cappedAfter) * sign))
            let best = bests[ply]
            plies.append(PlyReview(
                ply: ply, san: game.sans[ply], byPersona: mover == personaColor,
                bestSAN: best.map { before.san(for: $0) } ?? game.sans[ply],
                evalBefore: evals[ply], evalAfter: evals[ply + 1], loss: loss,
                judgement: Judgement.of(loss: loss, best: best == move),
                phase: GamePhase.of(before, ply: ply)))
        }
        return GameReview(
            plies: plies,
            persona: Self.stats(game, plies: plies, color: personaColor),
            opponent: Self.stats(game, plies: plies, color: personaColor.opposite))
    }

    static func stats(_ game: Game, plies: [PlyReview], color: PieceColor) -> SideStats {
        var s = SideStats()
        let mine = plies.filter { game.positions[$0.ply].sideToMove == color }
        s.moves = mine.count
        guard !mine.isEmpty else { return s }
        s.averageLoss = mine.map(\.loss).reduce(0, +) / mine.count
        s.inaccuracies = mine.filter { $0.judgement == .inaccuracy }.count
        s.mistakes = mine.filter { $0.judgement == .mistake }.count
        s.blunders = mine.filter { $0.judgement == .blunder }.count
        for phase in GamePhase.allCases {
            let inPhase = mine.filter { $0.phase == phase }
            if !inPhase.isEmpty { s.lossByPhase[phase] = inPhase.map(\.loss).reduce(0, +) / inPhase.count }
        }
        var pawnMoves = 0
        for review in mine {
            let san = review.san
            if san.hasPrefix("O-O-O") { s.castled = "queenside on move \(review.ply / 2 + 1)" }
            else if san.hasPrefix("O-O") { s.castled = "kingside on move \(review.ply / 2 + 1)" }
            if san.hasPrefix("Q") && review.ply < 20 { s.queenMovesBeforeMove10 += 1 }
            if san.contains("x") { s.captures += 1 }
            if san.contains("+") || san.contains("#") { s.checks += 1 }
            if let first = san.first, first.isLowercase { pawnMoves += 1 }
        }
        s.pawnMoveShare = pawnMoves * 100 / mine.count
        s.openingLine = Array(mine.prefix(6).map(\.san))
        return s
    }
}
