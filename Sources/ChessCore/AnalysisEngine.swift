import Foundation

/// What the move picker, the game review and the Lichess bot need from an engine. `StockfishEngine` (ChessEngine,
/// over UCI) is the Mac app's; `SearchEngine` (ChessSearch) runs in-process, where no subprocess may be started.
public protocol AnalysisEngine: Sendable {
    func start() async throws
    /// Forgets what earlier games taught the engine (its hash), before an unrelated game.
    func newGame() async throws
    func shutdown() async

    /// `fen` with `moves` (UCI, played from it) is the game so far: without the moves the engine cannot see a
    /// repetition. Up to `multiPV` lines, best first, scored from the side to move.
    func analyse(fen: String, moves: [String], multiPV: Int, limits: EngineLimits) async throws -> [EngineLine]
    /// Nil when the side to move has no legal move.
    func bestMove(fen: String, moves: [String], limits: EngineLimits) async throws -> String?
}

extension AnalysisEngine {
    public func analyse(fen: String, multiPV: Int, limits: EngineLimits) async throws -> [EngineLine] {
        try await analyse(fen: fen, moves: [], multiPV: multiPV, limits: limits)
    }

    public func bestMove(fen: String, limits: EngineLimits) async throws -> String? {
        try await bestMove(fen: fen, moves: [], limits: limits)
    }
}
