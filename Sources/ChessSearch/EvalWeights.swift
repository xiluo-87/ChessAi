import Foundation

/// The evaluation's numbers: centipawns by piece kind and square, material included, for the middlegame and the
/// endgame. The engine blends the two by the material left. `standard` holds the built-in values; `Training.tune`
/// fits others to game results, and `SearchEngine(weights:)` plays with them.
///
/// Each set is tagged with its training round: 0 is `standard`, and a set tuned from round n is round n + 1. The
/// rounds kept with the engine are in `Resources/Weights` (`bundled(round:)`), each with a note on its data and
/// how it played against the round before.
public struct EvalWeights: Codable, Sendable, Equatable {
    /// `[kind][square]`: kind 0 pawn, 1 knight, 2 bishop, 3 rook, 4 queen, 5 king; the square is seen from the
    /// piece's owner (0 is a1 for White and a8 for Black, so rank 0 is always its own back rank).
    public var middlegame: [[Int]]
    public var endgame: [[Int]]
    /// Training rounds behind these values: 0 for the hand-written standard ones.
    public var round: Int
    /// Positions the last round was fitted to (0 for the standard values).
    public var positions: Int
    /// Where the values come from: the data, the settings, and the match against the previous round.
    public var note: String

    public init(middlegame: [[Int]], endgame: [[Int]], round: Int = 0, positions: Int = 0, note: String = "") throws {
        guard middlegame.count == 6, endgame.count == 6,
              (middlegame + endgame).allSatisfy({ $0.count == 64 }) else {
            throw CocoaError(.coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "weights need 6 kinds of 64 squares"])
        }
        self.middlegame = middlegame
        self.endgame = endgame
        self.round = round
        self.positions = positions
        self.note = note
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
        return try! EvalWeights(
            middlegame: table(endgame: false), endgame: table(endgame: true), round: 0, positions: 0,
            note: "Standard: hand-written formulas in Evaluation.swift, untrained.")
    }()

    /// Whether the evaluation is the same, whatever the tags say.
    public func sameValues(as other: EvalWeights) -> Bool {
        middlegame == other.middlegame && endgame == other.endgame
    }

    // MARK: Bundled rounds

    /// The rounds kept with the engine, 0 up to the latest; they are numbered without gaps.
    public static var bundledRounds: [Int] {
        var rounds: [Int] = []
        while bundledURL(round: rounds.count) != nil { rounds.append(rounds.count) }
        return rounds
    }

    /// A round kept with the engine, from `Resources/Weights/round-N.json`.
    public static func bundled(round: Int) throws -> EvalWeights {
        guard let url = bundledURL(round: round) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no bundled weights for round \(round)"])
        }
        return try EvalWeights(contentsOf: url)
    }

    private static func bundledURL(round: Int) -> URL? {
        Bundle.module.url(forResource: "round-\(round)", withExtension: "json", subdirectory: "Weights")
    }

    // MARK: Files

    private enum CodingKeys: String, CodingKey { case middlegame, endgame, round, positions, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            middlegame: c.decode([[Int]].self, forKey: .middlegame), endgame: c.decode([[Int]].self, forKey: .endgame),
            round: c.decodeIfPresent(Int.self, forKey: .round) ?? 0,
            positions: c.decodeIfPresent(Int.self, forKey: .positions) ?? 0,
            note: c.decodeIfPresent(String.self, forKey: .note) ?? "")
    }

    public init(contentsOf url: URL) throws {
        self = try JSONDecoder().decode(EvalWeights.self, from: Data(contentsOf: url))
    }

    /// JSON with one row of 64 squares per line, so a new round reads as a diff of the rows that changed.
    public func write(to url: URL) throws {
        let quotedNote = String(decoding: try JSONEncoder().encode(note), as: UTF8.self)
        func rows(_ table: [[Int]]) -> String {
            table.map { "    [" + $0.map(String.init).joined(separator: ", ") + "]" }.joined(separator: ",\n")
        }
        let text = """
        {
          "round": \(round),
          "positions": \(positions),
          "note": \(quotedNote),
          "middlegame": [
        \(rows(middlegame))
          ],
          "endgame": [
        \(rows(endgame))
          ]
        }

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
