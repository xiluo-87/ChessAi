import Foundation
import ChessCore

/// What the last search did, for benchmarks and tests.
public struct SearchStats: Sendable {
    public var depth: Int
    public var nodes: Int
    public var milliseconds: Int
    public var nodesPerSecond: Int { milliseconds > 0 ? nodes * 1000 / milliseconds : nodes * 1000 }
}

/// An engine that runs in-process, for platforms where no subprocess may be started (iOS). Each search runs on its
/// own thread so it does not hold up Swift's cooperative pool, and stops at its depth or time limit, or soon after
/// the calling task is cancelled.
public actor SearchEngine: AnalysisEngine {
    private let hashMB: Int
    private var table: TranspositionTable?
    public private(set) var lastSearch: SearchStats?

    public init(hashMB: Int = 32) {
        self.hashMB = hashMB
    }

    // MARK: - Serialization

    /// The actor is reentrant while a search runs, and searches share the hash table: one at a time, in order.
    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { queued.append($0) }  // busy stays true: release hands the lock over
        } else {
            busy = true
        }
    }

    private func release() {
        if queued.isEmpty { busy = false } else { queued.removeFirst().resume() }
    }

    // MARK: - Lifecycle

    public func start() {
        if table == nil { table = TranspositionTable(megabytes: hashMB) }
    }

    public func newGame() {
        table?.clear()
    }

    /// Frees the hash table; searches then throw `EngineError.terminated` until `start()`.
    public func shutdown() {
        table = nil
    }

    // MARK: - Search

    public func analyse(fen: String, moves: [String], multiPV: Int, limits: EngineLimits) async throws -> [EngineLine] {
        await acquire()
        defer { release() }
        return try await search(fen: fen, moves: moves, multiPV: multiPV, limits: limits)
    }

    public func bestMove(fen: String, moves: [String], limits: EngineLimits) async throws -> String? {
        await acquire()
        defer { release() }
        return try await search(fen: fen, moves: moves, multiPV: 1, limits: limits).first?.move
    }

    /// Without limits it searches for a second, as `StockfishEngine` does. A cancelled task gets `CancellationError`.
    private func search(fen: String, moves: [String], multiPV: Int, limits: EngineLimits) async throws -> [EngineLine] {
        guard let table else { throw EngineError.terminated }
        let started = DispatchTime.now().uptimeNanoseconds
        let movetime = limits.movetimeMs ?? (limits.depth == nil ? 1000 : nil)
        let deadline = movetime.map { started + UInt64(max(1, $0)) * 1_000_000 }
        // An iteration takes several times the one before, so one begun after half the time would rarely finish.
        let softDeadline = movetime.map { started + UInt64(max(1, $0)) * 500_000 }
        let depthLimit = limits.depth ?? maxDepth
        let flag = StopFlag()
        let (lines, depth, nodes) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<([RootLine], Int, Int), Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let board = try Board(fen: fen, moves: moves, searchPlies: maxPly + 8)
                        let searcher = Searcher(board: board, tt: table, stop: flag, deadline: deadline)
                        let result = searcher.run(multiPV: multiPV, depthLimit: depthLimit, softDeadline: softDeadline)
                        done.resume(returning: (result.lines, result.depth, searcher.nodes))
                    } catch {
                        done.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        lastSearch = SearchStats(depth: depth, nodes: nodes, milliseconds: elapsed)
        try Task.checkCancellation()
        return lines.map { line in
            let pv = line.pv.map(\.uci)
            return EngineLine(move: pv[0], score: Searcher.engineScore(line.score), pv: pv, depth: depth)
        }
    }
}
