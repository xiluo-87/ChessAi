import Foundation
import ChessCore

/// A mate `n` plies from the root scores `mateScore - n`.
let mateScore = 32_000
let infinity = 32_500
let maxPly = 128
/// The deepest iteration, leaving plies for check extensions and the quiescence search.
let maxDepth = 64
/// Scores at least this large are mates.
let mateBound = mateScore - maxPly

/// Set from another thread (a cancelled task) and read by the search every 1024 nodes.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); value = true; lock.unlock()
    }
}

struct RootLine {
    var score: Int
    var pv: [PackedMove]
}

/// One search: negamax alpha-beta with principal variation search, iterative deepening and aspiration windows,
/// a quiescence search over captures, a transposition table, null-move pruning and late-move reductions. Moves are
/// tried TT move first, then captures by MVV-LVA, then killers, then quiet moves by history. Written from the
/// standard descriptions of these algorithms; no engine's code was used.
final class Searcher {
    private let board: Board
    private let tt: TranspositionTable
    private let stop: StopFlag
    /// Uptime in nanoseconds after which the search stops.
    private let deadline: UInt64?
    private let rootPly: Int
    private(set) var nodes = 0
    private var stopped = false
    /// Root moves already reported as better lines in this iteration (MultiPV).
    private var excluded: [PackedMove] = []

    /// Per ply: up to 256 generated moves and their ordering scores.
    private let moves = UnsafeMutablePointer<PackedMove>.allocate(capacity: maxPly * 256)
    private let scores = UnsafeMutablePointer<Int>.allocate(capacity: maxPly * 256)
    private let killers = UnsafeMutablePointer<PackedMove>.allocate(capacity: maxPly * 2)
    /// By side, from and to: how often a quiet move caused a cutoff, weighted by depth.
    private let history = UnsafeMutablePointer<Int>.allocate(capacity: 2 * 64 * 64)
    /// Triangular principal variation table.
    private let pv = UnsafeMutablePointer<PackedMove>.allocate(capacity: maxPly * maxPly)
    private let pvLength = UnsafeMutablePointer<Int>.allocate(capacity: maxPly + 1)

    init(board: Board, tt: TranspositionTable, stop: StopFlag, deadline: UInt64?) {
        self.board = board
        self.tt = tt
        self.stop = stop
        self.deadline = deadline
        rootPly = board.ply
        killers.initialize(repeating: .none, count: maxPly * 2)
        history.initialize(repeating: 0, count: 2 * 64 * 64)
        pvLength.initialize(repeating: 0, count: maxPly + 1)
    }

    deinit {
        moves.deallocate(); scores.deallocate(); killers.deallocate()
        history.deallocate(); pv.deallocate(); pvLength.deallocate()
    }

    // MARK: Iterative deepening

    /// Searches one depth deeper at a time until `depthLimit`, the deadline or a stop, and returns the lines of the
    /// deepest completed iteration, best first, with that depth. If even depth 1 is cut short, the moves are ranked
    /// by the evaluation one ply ahead (depth 0), so a legal position always gets a move. After an iteration that
    /// ends past `softDeadline`, the next is not started.
    func run(multiPV: Int, depthLimit: Int, softDeadline: UInt64?) -> (lines: [RootLine], depth: Int) {
        let wanted = min(max(1, multiPV), legalMoveCount())
        guard wanted > 0 else { return ([], 0) }
        var best: [RootLine] = []
        var completed = 0
        for depth in 1...max(1, min(depthLimit, maxDepth)) {
            excluded = []
            var lines: [RootLine] = []
            for k in 0..<wanted {
                let score = aspirate(depth, around: k == 0 && depth >= 4 ? best.first?.score : nil)
                if stopped { break }
                let line = (0..<pvLength[0]).map { pv[$0] }
                guard let first = line.first else { break }
                lines.append(RootLine(score: score, pv: line))
                excluded.append(first)
            }
            if stopped { break }
            // Each line was searched with the better ones excluded; a deeper look can still reorder them.
            best = lines.enumerated().sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }.map(\.element)
            completed = depth
            let now = DispatchTime.now().uptimeNanoseconds
            if stop.isSet || deadline.map({ now >= $0 }) == true || softDeadline.map({ now >= $0 }) == true { break }
        }
        if completed == 0 { best = Array(staticLines().prefix(wanted)) }
        return (best, completed)
    }

    private func staticLines() -> [RootLine] {
        let n = board.generate(moves, quiets: true)
        var lines: [RootLine] = []
        for i in 0..<n where board.make(moves[i]) {
            lines.append(RootLine(score: -board.evaluate(), pv: [moves[i]]))
            board.unmake()
        }
        return lines.sorted { $0.score > $1.score }
    }

    private func legalMoveCount() -> Int {
        let n = board.generate(moves, quiets: true)
        var legal = 0
        for i in 0..<n where board.make(moves[i]) {
            legal += 1
            board.unmake()
        }
        return legal
    }

    /// A narrow window around the previous iteration's score, widened when the score falls outside it.
    private func aspirate(_ depth: Int, around guess: Int?) -> Int {
        guard let guess, abs(guess) < mateBound else { return negamax(depth, -infinity, infinity, 0, allowNull: false) }
        var delta = 35
        var alpha = guess - delta, beta = guess + delta
        while true {
            let score = negamax(depth, alpha, beta, 0, allowNull: false)
            if stopped { return score }
            if score > alpha && score < beta { return score }
            delta *= 4
            if delta > 1_000 {
                alpha = -infinity; beta = infinity
            } else if score <= alpha {
                alpha = max(-infinity, guess - delta)
            } else {
                beta = min(infinity, guess + delta)
            }
        }
    }

    /// The quiescence search's score of the board as it stands, from the side to move. Equal to the static
    /// evaluation in a quiet position, which is what training wants.
    func quiescenceScore() -> Int {
        quiesce(-infinity, infinity, 0)
    }

    // MARK: Search

    @inline(__always) private func pollStop() {
        guard nodes & 1023 == 0 else { return }
        if stop.isSet || deadline.map({ DispatchTime.now().uptimeNanoseconds >= $0 }) == true { stopped = true }
    }

    private func negamax(_ depthLeft: Int, _ alphaIn: Int, _ betaIn: Int, _ ply: Int, allowNull: Bool) -> Int {
        pvLength[ply] = ply
        pollStop()
        if stopped { return 0 }
        let isRoot = ply == 0
        var alpha = alphaIn, beta = betaIn
        if !isRoot {
            if board.halfmove >= 100 || board.isInsufficientMaterial || board.isRepetition(rootPly: rootPly) { return 0 }
            // A mate found closer to the root cannot be beaten here.
            alpha = max(alpha, -mateScore + ply)
            beta = min(beta, mateScore - ply - 1)
            if alpha >= beta { return alpha }
        }
        let inCheck = board.inCheck
        let depth = inCheck ? depthLeft + 1 : depthLeft
        if depth <= 0 { return quiesce(alpha, beta, ply) }
        if ply >= maxPly - 2 || board.room < 4 { return board.evaluate() }
        nodes += 1
        let pvNode = beta - alpha > 1
        let alphaStart = alpha

        var ttMove = PackedMove.none
        if let entry = tt.probe(board.hash) {
            ttMove = entry.move
            if !pvNode && entry.depth >= depth {
                let s = Self.fromTable(entry.score, ply)
                switch entry.bound {
                case .exact: return s
                case .lower where s >= beta: return s
                case .upper where s <= alpha: return s
                default: break
                }
            }
        }

        // If passing still holds beta, a real move almost surely does; not in pawn endings, where passing can be
        // the only bad move (zugzwang).
        if !pvNode && !inCheck && allowNull && depth >= 3 && board.hasPieces && board.evaluate() >= beta {
            board.makeNull()
            let s = -negamax(depth - 3 - depth / 6, -beta, -beta + 1, ply + 1, allowNull: false)
            board.unmakeNull()
            if stopped { return 0 }
            if s >= beta { return s >= mateBound ? beta : s }
        }

        let list = moves + ply * 256, order = scores + ply * 256
        let n = board.generate(list, quiets: true)
        score(list, order, n, ttMove: ttMove, ply: ply)
        var best = -infinity, bestMove = PackedMove.none, legal = 0
        for i in 0..<n {
            pickNext(list, order, i, n)
            let m = list[i]
            if isRoot && excluded.contains(m) { continue }
            let quiet = !isCapture(m) && m.promotion == 0
            guard board.make(m) else { continue }
            legal += 1
            var s: Int
            if legal == 1 {
                s = -negamax(depth - 1, -beta, -alpha, ply + 1, allowNull: true)
            } else {
                // Late quiet moves rarely matter: search them shallower, and again at full depth if they surprise.
                var reduction = 0
                if depth >= 3 && legal > 3 && quiet && !inCheck && !board.inCheck
                    && m != killers[ply * 2] && m != killers[ply * 2 + 1] {
                    reduction = legal > 10 && depth >= 6 ? 2 : 1
                }
                s = -negamax(depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, allowNull: true)
                if s > alpha && reduction > 0 {
                    s = -negamax(depth - 1, -alpha - 1, -alpha, ply + 1, allowNull: true)
                }
                if s > alpha && s < beta {
                    s = -negamax(depth - 1, -beta, -alpha, ply + 1, allowNull: true)
                }
            }
            board.unmake()
            if stopped { return 0 }
            guard s > best else { continue }
            best = s
            bestMove = m
            guard s > alpha else { continue }
            alpha = s
            pv[ply * maxPly + ply] = m
            var j = ply + 1
            while j < pvLength[ply + 1] {
                pv[ply * maxPly + j] = pv[(ply + 1) * maxPly + j]
                j += 1
            }
            pvLength[ply] = max(pvLength[ply + 1], ply + 1)
            if alpha >= beta {
                if quiet { rememberCutoff(m, depth: depth, ply: ply) }
                break
            }
        }
        if legal == 0 {
            if isRoot && !excluded.isEmpty { return -infinity }
            return inCheck ? -mateScore + ply : 0
        }
        // With root moves excluded the result is not the position's own.
        if excluded.isEmpty || !isRoot {
            let bound: TranspositionTable.Bound = best >= beta ? .lower : best > alphaStart ? .exact : .upper
            tt.store(board.hash, move: bestMove, score: Self.toTable(best, ply), depth: depth, bound: bound)
        }
        return best
    }

    /// Captures (and evasions when in check) until the position is quiet, so a search never stops mid-exchange.
    private func quiesce(_ alphaIn: Int, _ beta: Int, _ ply: Int) -> Int {
        pvLength[ply] = ply
        pollStop()
        if stopped { return 0 }
        nodes += 1
        if ply >= maxPly - 2 || board.room < 4 { return board.evaluate() }
        var alpha = alphaIn
        let inCheck = board.inCheck
        var best = -infinity
        if !inCheck {
            let stand = board.evaluate()
            if stand >= beta { return stand }
            if stand > alpha { alpha = stand }
            best = stand
        }
        let list = moves + ply * 256, order = scores + ply * 256
        let n = board.generate(list, quiets: inCheck)
        score(list, order, n, ttMove: .none, ply: ply)
        var legal = 0
        for i in 0..<n {
            pickNext(list, order, i, n)
            let m = list[i]
            // Delta pruning: a capture that cannot lift the score near alpha even if it wins the piece outright.
            if !inCheck && m.promotion == 0 {
                let victim = board.squares[m.to] & 7
                if best + board.t.pieceValue[victim == 0 ? Code.pawn : victim] + 200 <= alpha { continue }
            }
            guard board.make(m) else { continue }
            legal += 1
            let s = -quiesce(-beta, -alpha, ply + 1)
            board.unmake()
            if stopped { return 0 }
            if s > best {
                best = s
                if s > alpha {
                    alpha = s
                    if s >= beta { break }
                }
            }
        }
        if inCheck && legal == 0 { return -mateScore + ply }
        return best
    }

    // MARK: Move ordering

    @inline(__always) private func isCapture(_ m: PackedMove) -> Bool {
        board.squares[m.to] != 0 || (board.squares[m.from] & 7 == Code.pawn && m.to == board.enPassant)
    }

    private func score(_ list: UnsafeMutablePointer<PackedMove>, _ order: UnsafeMutablePointer<Int>, _ n: Int, ttMove: PackedMove, ply: Int) {
        let side = board.side * 4096
        for i in 0..<n {
            let m = list[i]
            if m == ttMove { order[i] = 1 << 30; continue }
            let attacker = board.squares[m.from] & 7
            var victim = board.squares[m.to] & 7
            if victim == 0 && attacker == Code.pawn && m.to == board.enPassant { victim = Code.pawn }
            if victim != 0 {
                // Most valuable victim first, then least valuable attacker.
                order[i] = 1 << 24 + victim * 64 - attacker + (m.promotion == Code.queen ? 512 : 0)
            } else if m.promotion != 0 {
                order[i] = m.promotion == Code.queen ? 1 << 23 : -1
            } else if m == killers[ply * 2] {
                order[i] = 1 << 22 + 1
            } else if m == killers[ply * 2 + 1] {
                order[i] = 1 << 22
            } else {
                order[i] = history[side + m.from * 64 + m.to]
            }
        }
    }

    /// Selection sort, one step at a time: after a cutoff the rest need no ordering.
    @inline(__always) private func pickNext(_ list: UnsafeMutablePointer<PackedMove>, _ order: UnsafeMutablePointer<Int>, _ i: Int, _ n: Int) {
        var top = i
        for j in (i + 1)..<max(i + 1, n) where order[j] > order[top] { top = j }
        if top != i {
            (list[i], list[top]) = (list[top], list[i])
            (order[i], order[top]) = (order[top], order[i])
        }
    }

    private func rememberCutoff(_ m: PackedMove, depth: Int, ply: Int) {
        if killers[ply * 2] != m {
            killers[ply * 2 + 1] = killers[ply * 2]
            killers[ply * 2] = m
        }
        let i = board.side * 4096 + m.from * 64 + m.to
        history[i] += depth * depth
        // Kept below the killers' scores; halving keeps the order and lets newer cutoffs count.
        if history[i] > 1 << 20 {
            for k in 0..<(2 * 64 * 64) { history[k] /= 2 }
        }
    }

    // MARK: Scores

    /// Mates are stored relative to the position, not the root, so a transposition at another ply reads them right.
    static func toTable(_ s: Int, _ ply: Int) -> Int {
        s >= mateBound ? s + ply : s <= -mateBound ? s - ply : s
    }

    static func fromTable(_ s: Int, _ ply: Int) -> Int {
        s >= mateBound ? s - ply : s <= -mateBound ? s + ply : s
    }

    /// UCI's convention: centipawns, or moves to mate, negative when the side to move is mated.
    static func engineScore(_ s: Int) -> EngineScore {
        if s >= mateBound { return EngineScore(centipawns: nil, mate: (mateScore - s + 1) / 2) }
        if s <= -mateBound { return EngineScore(centipawns: nil, mate: -(mateScore + s) / 2) }
        return EngineScore(centipawns: s, mate: nil)
    }
}
