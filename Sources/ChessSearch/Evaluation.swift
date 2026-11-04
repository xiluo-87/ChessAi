import Foundation

/// Material plus piece-square tables, tapered between middlegame and endgame by the material left on the board.
///
/// Source of the values: written for this engine, not taken from any engine or published table. Each table is a
/// small formula over the square, from the usual opening and endgame advice: knights and bishops want the centre,
/// rooks the seventh rank, the king shelter behind its pawns in the middlegame and the centre in the endgame, and
/// pawns are worth more the further they have come. Untuned; Texel tuning against game results is left for later.
enum Evaluation {
    /// Centipawns by kind (index 1 pawn ... 6 king), middlegame and endgame.
    static let material: [(mg: Int, eg: Int)] = [
        (0, 0), (100, 120), (320, 300), (330, 320), (480, 530), (950, 980), (0, 0),
    ]

    /// How much each kind counts towards the middlegame: the start position sums to 24.
    static let phaseWeight = [0, 0, 1, 1, 2, 4, 0]
    static let fullPhase = 24

    /// The placement bonus of a piece of `kind` on square `s`, seen from its owner's side (rank 0 is its back rank).
    static func placement(_ kind: Int, _ s: Int, endgame: Bool) -> Int {
        let file = s & 7, rank = s >> 3
        // 0 in a corner up to 6 on the four centre squares.
        let centre = 7 - (abs(2 * file - 7) + abs(2 * rank - 7)) / 2
        switch kind {
        case Code.pawn:
            if endgame { return [0, 0, 5, 12, 24, 40, 65, 0][rank] }
            let central = file == 3 || file == 4
            let advance = [0, 0, 4, 8, 12, 18, 30, 0][rank]
            if central { return advance + (rank == 1 ? -8 : rank == 3 || rank == 4 ? 14 : 4) }
            if file == 2 || file == 5 { return advance + (rank == 3 ? 6 : 0) }
            return advance
        case Code.knight:
            return endgame ? -25 + 7 * centre : -30 + 8 * centre - (rank == 0 ? 6 : 0)
        case Code.bishop:
            return endgame ? -8 + 3 * centre : -10 + 4 * centre - (rank == 0 ? 6 : 0)
        case Code.rook:
            if rank == 6 { return endgame ? 12 : 18 }
            if endgame { return 0 }
            return rank == 0 && (file == 3 || file == 4) ? 6 : 0
        case Code.queen:
            return endgame ? -15 + 4 * centre : -6 + 2 * centre
        case Code.king:
            if endgame { return -40 + 10 * centre }
            let backRank = [10, 25, 15, -5, 0, -5, 25, 15][file]
            return rank == 0 ? backRank : backRank - 18 * rank - 10
        default:
            return 0
        }
    }
}

extension Board {
    /// Centipawns from the side to move.
    @inline(__always) func evaluate() -> Int {
        let p = min(phase, Evaluation.fullPhase)
        let score = (middlegame * p + endgame * (Evaluation.fullPhase - p)) / Evaluation.fullPhase
        return side == 0 ? score : -score
    }
}
