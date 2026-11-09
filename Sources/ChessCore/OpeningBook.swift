import Foundation

/// Opening moves to play from known positions, each with a weight: how many of the opening lines the book was built
/// from take it. Stored as text, one position per line: the first four FEN fields, " ; ", then "uci weight" pairs.
public struct OpeningBook: Sendable {
    public struct Entry: Sendable, Hashable {
        public var move: String
        public var weight: Int

        public init(move: String, weight: Int) {
            self.move = move
            self.weight = weight
        }
    }

    private var entries: [String: [Entry]]

    public init(entries: [String: [Entry]] = [:]) {
        self.entries = entries
    }

    /// Lines starting with `#` and blank lines are skipped.
    public init(text: String) throws {
        var entries: [String: [Entry]] = [:]
        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let halves = trimmed.components(separatedBy: " ; ")
            let fields = halves.last?.split(separator: " ") ?? []
            guard halves.count == 2, fields.count % 2 == 0, !fields.isEmpty else {
                throw BookError.badLine(number + 1)
            }
            entries[halves[0]] = try stride(from: 0, to: fields.count, by: 2).map { i in
                guard let weight = Int(fields[i + 1]), weight > 0 else { throw BookError.badLine(number + 1) }
                return Entry(move: String(fields[i]), weight: weight)
            }
        }
        self.entries = entries
    }

    public init(contentsOf url: URL) throws {
        try self.init(text: String(contentsOf: url, encoding: .utf8))
    }

    public enum BookError: Error {
        case badLine(Int)
    }

    /// The book's key for a position: its FEN without the move counters, so transpositions share an entry.
    public static func key(_ position: Position) -> String {
        position.fen.split(separator: " ").prefix(4).joined(separator: " ")
    }

    public var count: Int { entries.count }

    /// The book's legal moves here, most played first.
    public func moves(at position: Position) -> [Entry] {
        (entries[Self.key(position)] ?? [])
            .filter { Move(uci: $0.move).map(position.isLegal) ?? false }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.move < $1.move }
    }

    /// A book move chosen at random in proportion to its weight, or nil when the position is not in the book.
    public func pick<R: RandomNumberGenerator>(at position: Position, using generator: inout R) -> Move? {
        let options = moves(at: position)
        let total = options.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var roll = Int.random(in: 0..<total, using: &generator)
        for option in options {
            roll -= option.weight
            if roll < 0 { return Move(uci: option.move) }
        }
        return nil
    }

    public func pick(at position: Position) -> Move? {
        var generator = SystemRandomNumberGenerator()
        return pick(at: position, using: &generator)
    }

    /// The book as text, positions in a stable order so a rebuilt book reads as a diff.
    public func text(header: [String] = []) -> String {
        let lines = entries.keys.sorted().map { key in
            key + " ; " + entries[key]!.map { "\($0.move) \($0.weight)" }.joined(separator: " ")
        }
        return (header.map { "# " + $0 } + lines).joined(separator: "\n") + "\n"
    }
}

// MARK: - Building

extension OpeningBook {
    /// SAN lines from tab-separated files with a `pgn` column, such as the CC0 lists of named openings in
    /// github.com/lichess-org/chess-openings: "1. e4 e5 2. Nf3" becomes ["e4", "e5", "Nf3"].
    public static func lines(fromTSV text: String) -> [[String]] {
        var rows = text.split(separator: "\n").map { $0.components(separatedBy: "\t") }
        guard let header = rows.first, let column = header.firstIndex(of: "pgn") else { return [] }
        rows.removeFirst()
        return rows.compactMap { row in
            guard column < row.count else { return nil }
            let sans = row[column].split(separator: " ").map(String.init).filter { !$0.contains(".") && !$0.isEmpty }
            return sans.isEmpty ? nil : sans
        }
    }

    /// A book from opening lines, each move kept only if the engine finds it no more than `marginCp` worse than its
    /// best move there. Lines are cut after `plies`; a line with an illegal move stops at it. A position the engine
    /// fails on twice is left out.
    public static func build(
        lines: [[String]], plies: Int, marginCp: Int, engine: any AnalysisEngine, limits: EngineLimits,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> OpeningBook {
        // Every move the lines play from each position, with how many lines play it.
        var played: [String: [String: Int]] = [:]
        var positions: [String: Position] = [:]
        for line in lines {
            var position = Position.start
            for san in line.prefix(plies) {
                guard let move = position.move(fromSAN: san) else { break }
                let key = key(position)
                positions[key] = position
                played[key, default: [:]][move.uci, default: 0] += 1
                position = position.applying(move)
                positions[Self.key(position)] = position
            }
        }

        // Each position's score for its side to move, analysed once even when several lines reach it.
        var scores: [String: Int] = [:]
        let total = positions.count
        for (index, (key, position)) in positions.sorted(by: { $0.key < $1.key }).enumerated() {
            if position.legalMoves().isEmpty {
                scores[key] = position.isCheckmate() ? -100_000 : 0
            } else if let line = await analyse(position, engine: engine, limits: limits) {
                scores[key] = line.score.normalized
            }
            progress(index + 1, total)
        }

        var entries: [String: [Entry]] = [:]
        for (key, moves) in played {
            guard let position = positions[key], let best = scores[key] else { continue }
            let kept = moves.compactMap { uci, count -> Entry? in
                guard let move = Move(uci: uci), let after = scores[Self.key(position.applying(move))],
                      best - (-after) <= marginCp else { return nil }
                return Entry(move: uci, weight: count)
            }
            if !kept.isEmpty { entries[key] = kept.sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.move < $1.move } }
        }
        return OpeningBook(entries: entries)
    }

    /// The engine's top line, tried twice; nil when both fail, which leaves the position and the moves into it out.
    private static func analyse(_ position: Position, engine: any AnalysisEngine, limits: EngineLimits) async -> EngineLine? {
        for _ in 0..<2 {
            if let line = try? await engine.analyse(fen: position.fen, multiPV: 1, limits: limits).first { return line }
        }
        return nil
    }
}
