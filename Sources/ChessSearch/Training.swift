import Foundation
import ChessCore

/// A quiet position from a finished game, and how that game ended from White's side: 1, 0.5 or 0.
public struct TrainingPosition: Sendable, Equatable {
    public var fen: String
    public var result: Double

    public init(fen: String, result: Double) {
        self.fen = fen
        self.result = result
    }
}

/// Games between two sets of weights, from the candidate's side.
public struct MatchTally: Sendable, Equatable {
    public var wins = 0
    public var draws = 0
    public var losses = 0

    public var games: Int { wins + draws + losses }
    public var score: Double { games == 0 ? 0 : (Double(wins) + Double(draws) / 2) / Double(games) }
    /// The rating difference that score implies; nil at 0 % or 100 %.
    public var eloDifference: Double? {
        score > 0 && score < 1 ? -400 * log10(1 / score - 1) : nil
    }
}

public struct TuningReport: Sendable {
    /// The scale that turns centipawns into an expected result: 1 / (1 + exp(-k * eval)).
    public var k: Double
    public var trainingPositions: Int
    public var validationPositions: Int
    /// Mean squared error of the predicted results, before and after (on held-out positions when there are any).
    public var lossBefore: Double
    public var lossAfter: Double
    public var epochs: Int
}

/// Training the evaluation (Texel's method): collect quiet positions from games with known results, then fit the
/// weights so that a sigmoid of the evaluation predicts those results. The evaluation is linear in its weights, so
/// the fit is plain gradient descent (Adam) on the mean squared error, with no search in the loop.
///
/// Positions come from the engine's own games (`selfPlay`) or from any PGN (`positions(fromPGN:)`); `compare`
/// plays tuned weights against others to check that the fit made the engine stronger, not just the error lower.
public enum Training {
    // MARK: Files

    /// One position per line: the FEN, " ; " and the result.
    public static func write(_ positions: [TrainingPosition], to url: URL) throws {
        let text = positions.map { "\($0.fen) ; \($0.result)" }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Adds to the end of the file, creating it (and its folder) if needed.
    public static func append(_ positions: [TrainingPosition], to url: URL) throws {
        guard !positions.isEmpty else { return }
        let data = Data(positions.map { "\($0.fen) ; \($0.result)\n" }.joined().utf8)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func read(from url: URL) throws -> [TrainingPosition] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ";")
            guard parts.count == 2, let result = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
            return TrainingPosition(fen: parts[0].trimmingCharacters(in: .whitespaces), result: result)
        }
    }

    // MARK: Games

    /// The engine plays itself at `depth`, each game opened with `randomPlies` random moves so the games differ.
    /// Games run in parallel; `progress` gets the number finished.
    public static func selfPlay(
        games: Int, depth: Int, weights: EvalWeights = .standard, randomPlies: Int = 8, seed: UInt64 = 1,
        progress: (@Sendable (Int) -> Void)? = nil
    ) -> [TrainingPosition] {
        let tables = weights.sameValues(as: .standard) ? Tables.shared : Tables(weights: weights)
        let collected = Collector<[TrainingPosition]>()
        DispatchQueue.concurrentPerform(iterations: games) { i in
            let game = play(white: tables, black: tables, depth: depth, randomPlies: randomPlies,
                            seed: gameSeed(seed, i), record: true)
            let done = collected.add(game.positions.map { TrainingPosition(fen: $0, result: game.result) })
            progress?(done)
        }
        return collected.items.flatMap { $0 }
    }

    /// `candidate` against `baseline` at `depth`: each random opening is played twice, once with either colour.
    public static func compare(
        _ candidate: EvalWeights, against baseline: EvalWeights, games: Int, depth: Int, randomPlies: Int = 8,
        seed: UInt64 = 1, progress: (@Sendable (Int) -> Void)? = nil
    ) -> MatchTally {
        let ours = Tables(weights: candidate), theirs = Tables(weights: baseline)
        let collected = Collector<Double>()
        DispatchQueue.concurrentPerform(iterations: games) { i in
            let candidateWhite = i % 2 == 0
            let game = play(white: candidateWhite ? ours : theirs, black: candidateWhite ? theirs : ours, depth: depth,
                            randomPlies: randomPlies, seed: gameSeed(seed, i / 2), record: false)
            let done = collected.add(candidateWhite ? game.result : 1 - game.result)
            progress?(done)
        }
        var tally = MatchTally()
        for score in collected.items {
            if score == 1 { tally.wins += 1 } else if score == 0 { tally.losses += 1 } else { tally.draws += 1 }
        }
        return tally
    }

    private static func gameSeed(_ seed: UInt64, _ i: Int) -> UInt64 {
        seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(i) &* 0xD1B5_4A32_D192_ED03
    }

    static let maxGamePlies = 300

    /// One game from the start position. Each side searches on its own board, since its evaluation is kept
    /// incrementally with its own weights. A game ends by the rules, after 8 plies in a row with one side ahead by
    /// 10 pawns or more (adjudicated), or as a draw at `maxGamePlies`.
    static func play(white: Tables, black: Tables, depth: Int, randomPlies: Int, seed: UInt64, record: Bool)
        -> (result: Double, positions: [String]) {
        var rng = SplitMix64(seed: seed)
        let room = maxGamePlies + maxPly + 16
        let boards = [try! Board(fen: Position.start.fen, searchPlies: room, tables: white),
                      white === black ? nil : try! Board(fen: Position.start.fen, searchPlies: room, tables: black)]
        let tts = [TranspositionTable(megabytes: 4), TranspositionTable(megabytes: 4)]
        let referee = boards[0]!
        let buffer = UnsafeMutablePointer<PackedMove>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        var positions: [String] = []
        var ahead = 0, aheadSign = 0
        for ply in 0..<maxGamePlies {
            let n = referee.generate(buffer, quiets: true)
            var legal: [PackedMove] = []
            for i in 0..<n where referee.make(buffer[i]) {
                legal.append(buffer[i])
                referee.unmake()
            }
            if legal.isEmpty {
                return (referee.inCheck ? (referee.side == 0 ? 0 : 1) : 0.5, positions)
            }
            if referee.halfmove >= 100 || referee.isInsufficientMaterial || referee.isRepetition(rootPly: referee.ply + 1) {
                return (0.5, positions)
            }
            let mover = referee.side
            let move: PackedMove
            if ply < randomPlies {
                move = legal[Int(rng.next() % UInt64(legal.count))]
            } else {
                let board = boards[mover] ?? referee
                let searcher = Searcher(board: board, tt: tts[mover], stop: StopFlag(), deadline: nil)
                if record && !board.inCheck && searcher.quiescenceScore() == board.evaluate() {
                    positions.append(board.fen)
                }
                let line = searcher.run(multiPV: 1, depthLimit: depth, softDeadline: nil).lines[0]
                move = line.pv[0]
                let white = mover == 0 ? line.score : -line.score
                let sign = white >= 1_000 ? 1 : white <= -1_000 ? -1 : 0
                ahead = sign != 0 && sign == aheadSign ? ahead + 1 : (sign != 0 ? 1 : 0)
                aheadSign = sign
                if ahead >= 8 { return (sign > 0 ? 1 : 0, positions) }
            }
            for board in boards { board?.make(move) }
        }
        return (0.5, positions)
    }

    // MARK: Finished games

    /// The result as training wants it: 1 for a White win, 0.5 for a draw, 0 for a Black win; nil while unfinished.
    public static func value(of result: GameResult) -> Double? {
        switch result {
        case .whiteWins: 1
        case .draw: 0.5
        case .blackWins: 0
        case .ongoing: nil
        }
    }

    /// Quiet positions of one finished game (`moves` in UCI from `fen`), from ply `skipPlies` on.
    public static func positions(fen: String, moves: [String], result: GameResult, skipPlies: Int = 8) -> [TrainingPosition] {
        guard let value = value(of: result) else { return [] }
        return collect(fen: fen, plies: moves.count, result: value, skipPlies: skipPlies) { board, i in
            guard let m = Move(uci: moves[i]) else { return nil }
            return legalMoves(board).first {
                $0.from == m.from && $0.to == m.to && $0.promotion == (m.promotion.map(Board.code(of:)) ?? 0)
            }
        }
    }

    // MARK: PGN

    /// Quiet positions from every game in `text` with a result, from ply `skipPlies` on (openings are mostly book).
    /// `result`, when given, overrides the games' own: a record may know an ending (a loss on time) its moves do not.
    public static func positions(fromPGN text: String, skipPlies: Int = 8, result: GameResult? = nil) -> [TrainingPosition] {
        var out: [TrainingPosition] = []
        for game in splitPGN(text) {
            var tokens = movetextTokens(game.movetext)
            var value = result.flatMap(Self.value(of:)) ?? resultValue(game.tags["Result"] ?? "")
            if let last = tokens.last, let r = resultValue(last) { value = value ?? r }
            tokens.removeAll { resultValue($0) != nil || $0 == "*" }
            guard let value else { continue }
            out += collect(fen: game.tags["FEN"] ?? Position.start.fen, plies: tokens.count, result: value, skipPlies: skipPlies) {
                board, i in move(fromSAN: tokens[i], on: board)
            }
        }
        return out
    }

    /// Plays a game's moves on a search board, keeping each quiet position from ply `skipPlies` on. A move that does
    /// not read (a broken game) ends it there, keeping what came before.
    private static func collect(
        fen: String, plies: Int, result: Double, skipPlies: Int, move: (Board, Int) -> PackedMove?
    ) -> [TrainingPosition] {
        guard let board = try? Board(fen: fen, searchPlies: plies + maxPly + 16) else { return [] }
        let searcher = Searcher(board: board, tt: TranspositionTable(megabytes: 1), stop: StopFlag(), deadline: nil)
        var out: [TrainingPosition] = []
        for ply in 0..<plies {
            guard let m = move(board, ply), board.make(m) else { break }
            if ply + 1 >= skipPlies && !board.inCheck && searcher.quiescenceScore() == board.evaluate() {
                out.append(TrainingPosition(fen: board.fen, result: result))
            }
        }
        return out
    }

    private static func legalMoves(_ board: Board) -> [PackedMove] {
        let buffer = UnsafeMutablePointer<PackedMove>.allocate(capacity: 256)
        defer { buffer.deallocate() }
        var legal: [PackedMove] = []
        for i in 0..<board.generate(buffer, quiets: true) where board.make(buffer[i]) {
            legal.append(buffer[i])
            board.unmake()
        }
        return legal
    }

    static func resultValue(_ token: String) -> Double? {
        switch token {
        case "1-0": return 1
        case "0-1": return 0
        case "1/2-1/2": return 0.5
        default: return nil
        }
    }

    static func splitPGN(_ text: String) -> [(tags: [String: String], movetext: String)] {
        var games: [(tags: [String: String], movetext: String)] = []
        var tags: [String: String] = [:], movetext = ""
        func flush() {
            if !movetext.trimmingCharacters(in: .whitespaces).isEmpty { games.append((tags, movetext)) }
            tags = [:]; movetext = ""
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                if !movetext.trimmingCharacters(in: .whitespaces).isEmpty { flush() }
                let body = line.dropFirst().dropLast()
                guard let space = body.firstIndex(of: " ") else { continue }
                tags[String(body[..<space])] = body[space...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if !line.hasPrefix("%") {
                movetext += " " + line
            }
        }
        flush()
        return games
    }

    /// SAN moves and the result, without comments, variations, NAGs and move numbers.
    static func movetextTokens(_ movetext: String) -> [String] {
        var clean = ""
        var braces = 0, parens = 0, lineComment = false
        for ch in movetext {
            if lineComment { if ch == "\n" { lineComment = false }; continue }
            switch ch {
            case "{": braces += 1
            case "}": braces = max(0, braces - 1)
            case "(" where braces == 0: parens += 1
            case ")" where braces == 0: parens = max(0, parens - 1)
            case ";" where braces == 0: lineComment = true
            default: if braces == 0 && parens == 0 { clean.append(ch) }
            }
        }
        return clean.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { token in
            var t = Substring(token)
            if t.hasPrefix("$") { return nil }
            // "12." "12..." and "12.e4"
            while let first = t.first, first.isNumber, t.contains(".") { t = t.dropFirst() }
            while t.first == "." { t = t.dropFirst() }
            return t.isEmpty ? nil : String(t)
        }
    }

    /// Reads SAN on the search board, which is much faster than ChessCore's `move(fromSAN:)` for whole databases.
    static func move(fromSAN san: String, on board: Board) -> PackedMove? {
        var t = Array(san.filter { !"+#!?x".contains($0) }.replacingOccurrences(of: "0", with: "O"))
        let legal = legalMoves(board)
        let kingFrom = board.side == 0 ? 4 : 60
        if t.starts(with: Array("O-O-O")) || t.starts(with: Array("O-O")) {
            let to = kingFrom + (t.count >= 5 ? -2 : 2)
            return legal.first { $0.from == kingFrom && $0.to == to && board.squares[kingFrom] & 7 == Code.king }
        }
        var promotion = 0
        if let last = t.last, let kind = ["N": Code.knight, "B": Code.bishop, "R": Code.rook, "Q": Code.queen][last],
           t.count >= 3 {
            promotion = kind
            t.removeLast()
            if t.last == "=" { t.removeLast() }
        }
        var kind = Code.pawn
        if let first = t.first, let k = ["N": Code.knight, "B": Code.bishop, "R": Code.rook, "Q": Code.queen, "K": Code.king][first] {
            kind = k
            t.removeFirst()
        }
        guard t.count >= 2, let to = Squares.parse(String(t.suffix(2))) else { return nil }
        let hint = t.dropLast(2)
        let matches = legal.filter { m in
            guard m.to == to, board.squares[m.from] & 7 == kind, m.promotion == promotion else { return false }
            return hint.allSatisfy { c in
                if let f = "abcdefgh".firstIndex(of: c) { return m.from & 7 == "abcdefgh".distance(from: "abcdefgh".startIndex, to: f) }
                if let r = c.wholeNumberValue { return m.from >> 3 == r - 1 }
                return true
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: Tuning

    /// Fits `start` to `positions`. About a tenth of them (with at least 1,000 positions in all) is held out, in
    /// runs of 64 consecutive positions: positions of one game share its result, so holding out single positions
    /// would leak the answers. The weights that predict the held-out results best are kept, and fitting stops once
    /// they have not improved for 50 epochs. `regularization` pulls each weight towards its start, so squares seen
    /// in few positions keep sensible values. The result is tagged one round after `start`.
    public static func tune(
        _ positions: [TrainingPosition], from start: EvalWeights = .standard, epochs: Int = 1_000,
        learningRate: Double = 1, regularization: Double = 1e-7, log: ((String) -> Void)? = nil
    ) -> (weights: EvalWeights, report: TuningReport) {
        var rng = SplitMix64(seed: 99)
        let block = 64
        var validationSet: [TrainingPosition] = [], trainingSet: [TrainingPosition] = []
        for first in stride(from: 0, to: positions.count, by: block) {
            let run = positions[first..<min(first + block, positions.count)]
            if positions.count >= 1_000 && rng.next() % 10 == 0 { validationSet += run } else { trainingSet += run }
        }
        let held = validationSet.count
        let validation = Features(validationSet)
        let training = Features(trainingSet)

        var w = (start.middlegame + start.endgame).flatMap { $0 }.map(Double.init)
        let origin = w
        let k = training.bestScale(w)
        let check = held > 0 ? validation : training
        let before = check.loss(w, k: k)
        log?(String(format: "%d training, %d held-out positions; k %.5f; error %.6f", training.count, held, k, before))

        var best = w, bestLoss = before, bestEpoch = 0
        var m = [Double](repeating: 0, count: w.count), v = m
        let beta1 = 0.9, beta2 = 0.999
        var epoch = 0
        while epoch < epochs {
            epoch += 1
            var gradient = training.gradient(w, k: k)
            for j in w.indices { gradient[j] += 2 * regularization * (w[j] - origin[j]) }
            for j in w.indices where gradient[j] != 0 {
                m[j] = beta1 * m[j] + (1 - beta1) * gradient[j]
                v[j] = beta2 * v[j] + (1 - beta2) * gradient[j] * gradient[j]
                let mHat = m[j] / (1 - pow(beta1, Double(epoch))), vHat = v[j] / (1 - pow(beta2, Double(epoch)))
                w[j] -= learningRate * mHat / (vHat.squareRoot() + 1e-12)
            }
            let loss = check.loss(w, k: k)
            if loss < bestLoss { best = w; bestLoss = loss; bestEpoch = epoch }
            if epoch % 25 == 0 { log?(String(format: "epoch %d: error %.6f (best %.6f at %d)", epoch, loss, bestLoss, bestEpoch)) }
            if epoch - bestEpoch >= 50 { break }
        }
        let rounded = best.map { Int($0.rounded()) }
        let weights = try! EvalWeights(
            middlegame: (0..<6).map { Array(rounded[($0 * 64)..<($0 * 64 + 64)]) },
            endgame: (0..<6).map { Array(rounded[(384 + $0 * 64)..<(384 + $0 * 64 + 64)]) },
            round: start.round + 1, positions: training.count,
            note: String(format: "Round %d: tuned from round %d on %d positions (held-out error %.6f -> %.6f).",
                         start.round + 1, start.round, training.count, before, check.loss(rounded.map(Double.init), k: k)))
        let report = TuningReport(
            k: k, trainingPositions: training.count, validationPositions: held, lossBefore: before,
            lossAfter: check.loss(rounded.map(Double.init), k: k), epochs: epoch)
        return (weights, report)
    }

    /// Each position as the weights it uses and how much: the evaluation from White's side is the sum of
    /// weight times coefficient. Indices 0..<384 are middlegame `[kind * 64 + square]`, 384..<768 endgame.
    struct Features {
        var start: [Int] = [0]
        var index: [Int32] = []
        var coefficient: [Double] = []
        var result: [Double] = []
        var count: Int { result.count }

        init(_ positions: [TrainingPosition]) {
            for position in positions {
                guard let board = try? Board(fen: position.fen, searchPlies: 1) else { continue }
                let middle = Double(min(board.phase, Evaluation.fullPhase)) / Double(Evaluation.fullPhase)
                for s in 0..<64 where board.squares[s] != 0 {
                    let p = board.squares[s], black = p & Code.black != 0
                    let square = (p & 7 - 1) * 64 + (black ? s ^ 56 : s)
                    let sign: Double = black ? -1 : 1
                    index.append(Int32(square)); coefficient.append(sign * middle)
                    index.append(Int32(384 + square)); coefficient.append(sign * (1 - middle))
                }
                start.append(index.count)
                result.append(position.result)
            }
        }

        @inline(__always) func evaluation(_ i: Int, _ w: [Double]) -> Double {
            var e = 0.0
            for f in start[i]..<start[i + 1] { e += coefficient[f] * w[Int(index[f])] }
            return e
        }

        func loss(_ w: [Double], k: Double) -> Double {
            guard count > 0 else { return 0 }
            var total = 0.0
            for i in 0..<count {
                let d = result[i] - 1 / (1 + exp(-k * evaluation(i, w)))
                total += d * d
            }
            return total / Double(count)
        }

        func gradient(_ w: [Double], k: Double) -> [Double] {
            var g = [Double](repeating: 0, count: w.count)
            guard count > 0 else { return g }
            for i in 0..<count {
                let p = 1 / (1 + exp(-k * evaluation(i, w)))
                let factor = -2 * (result[i] - p) * p * (1 - p) * k / Double(count)
                for f in start[i]..<start[i + 1] { g[Int(index[f])] += factor * coefficient[f] }
            }
            return g
        }

        /// The k at which the starting weights predict best (golden-section search).
        func bestScale(_ w: [Double]) -> Double {
            var a = 0.0005, b = 0.05
            let ratio = (5.0.squareRoot() - 1) / 2
            for _ in 0..<40 {
                let c = b - ratio * (b - a), d = a + ratio * (b - a)
                if loss(w, k: c) < loss(w, k: d) { b = d } else { a = c }
            }
            return (a + b) / 2
        }
    }
}

/// Results from parallel games, in the order they finish.
private final class Collector<T>: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [T] = []

    func add(_ item: T) -> Int {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
        return items.count
    }
}

struct SplitMix64 {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed &+= 0x9E37_79B9_7F4A_7C15
        var z = seed
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
