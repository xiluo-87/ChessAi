import Foundation

/// The evaluation's numbers: centipawns by piece kind and square, material included, for the middlegame and the
/// endgame. The engine blends the two by the material left. `standard` holds the built-in values; `Training.tune`
/// fits others to game results, and `SearchEngine(weights:)` plays with them.
public struct EvalWeights: Codable, Sendable, Equatable {
    /// `[kind][square]`: kind 0 pawn, 1 knight, 2 bishop, 3 rook, 4 queen, 5 king; the square is seen from the
    /// piece's owner (0 is a1 for White and a8 for Black, so rank 0 is always its own back rank).
    public var middlegame: [[Int]]
    public var endgame: [[Int]]

    public init(middlegame: [[Int]], endgame: [[Int]]) throws {
        guard middlegame.count == 6, endgame.count == 6,
              (middlegame + endgame).allSatisfy({ $0.count == 64 }) else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "weights need 6 kinds of 64 squares"])
        }
        self.middlegame = middlegame
        self.endgame = endgame
    }

    public static let standard: EvalWeights = {
        func table(endgame: Bool) -> [[Int]] {
            (1...6).map { kind in
                (0..<64).map { s in
                    let material = Evaluation.material[kind]
                    return (endgame ? material.eg : material.mg) + Evaluation.placement(kind, s, endgame: endgame)
                }
            }
        }
        return try! EvalWeights(middlegame: table(endgame: false), endgame: table(endgame: true))
    }()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(middlegame: c.decode([[Int]].self, forKey: .middlegame), endgame: c.decode([[Int]].self, forKey: .endgame))
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(EvalWeights.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
