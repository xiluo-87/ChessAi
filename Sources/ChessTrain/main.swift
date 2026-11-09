import Foundation
import ChessCore
import ChessEngine
import ChessSearch

// chessai-train: tune ChessSearch's evaluation against game results.
//
//   chessai-train selfplay --games N [--depth D] [--random-plies P] [--weights W] [--seed S] --out POSITIONS
//   chessai-train pgn GAMES.pgn... --out POSITIONS
//   chessai-train tune POSITIONS... [--from W] [--epochs E] [--rate R] [--regularization L] --out W.json
//   chessai-train compare W [--against W] [--games N] [--depth D] [--record]
//   chessai-train rounds
//   chessai-train book OPENINGS.tsv... [--plies P] [--margin CP] [--depth D] [--engine stockfish|chesssearch] --out BOOK
//
// W is a weights file or round:N, a round kept with the engine (round:0 is the standard values). A typical round:
// self-play with the latest round, tune from it, then compare the result with it; --record adds the match to the
// new file's note. A round worth keeping goes to Sources/ChessSearch/Resources/Weights/round-N.json.
//
// `book` turns lists of opening lines (tab-separated with a `pgn` column) into ChessSearch's opening book, keeping only
// moves the engine finds within the margin of its best. The book goes to Sources/ChessSearch/Resources/Book.

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Options that take no value.
let flags: Set = ["--record"]

/// Arguments that are neither options nor their values.
var inputs: [String] {
    var out: [String] = []
    var i = 1
    while i < args.count {
        if flags.contains(args[i]) { i += 1 } else if args[i].hasPrefix("--") { i += 2 } else { out.append(args[i]); i += 1 }
    }
    return out
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func weights(_ path: String?) -> EvalWeights {
    guard let path else { return .standard }
    do {
        if path.hasPrefix("round:"), let round = Int(path.dropFirst(6)) { return try EvalWeights.bundled(round: round) }
        return try EvalWeights(contentsOf: URL(fileURLWithPath: path))
    } catch {
        fail("cannot read weights \(path): \(error)")
    }
}

func output() -> URL {
    guard let path = option("--out") else { fail("--out is required") }
    return URL(fileURLWithPath: path)
}

let started = Date()
func elapsed() -> String { String(format: "%.0f s", Date().timeIntervalSince(started)) }

switch args.first {
case "selfplay":
    guard let games = option("--games").flatMap(Int.init), games > 0 else { fail("--games N is required") }
    let out = output()
    let positions = Training.selfPlay(
        games: games, depth: option("--depth").flatMap(Int.init) ?? 5, weights: weights(option("--weights")),
        randomPlies: option("--random-plies").flatMap(Int.init) ?? 8,
        seed: option("--seed").flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970)
    ) { done in
        if done % max(1, games / 20) == 0 || done == games { print("\(done)/\(games) games, \(elapsed())") }
    }
    try Training.write(positions, to: out)
    print("\(positions.count) positions written to \(out.path)")

case "pgn":
    let out = output()
    var positions: [TrainingPosition] = []
    for path in inputs {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
        let found = Training.positions(fromPGN: text)
        print("\(path): \(found.count) positions")
        positions += found
    }
    try Training.write(positions, to: out)
    print("\(positions.count) positions written to \(out.path)")

case "tune":
    let out = output()
    var positions: [TrainingPosition] = []
    for path in inputs { positions += try Training.read(from: URL(fileURLWithPath: path)) }
    guard !positions.isEmpty else { fail("no positions in \(inputs)") }
    let (tuned, report) = Training.tune(
        positions, from: weights(option("--from")), epochs: option("--epochs").flatMap(Int.init) ?? 1_000,
        learningRate: option("--rate").flatMap(Double.init) ?? 1,
        regularization: option("--regularization").flatMap(Double.init) ?? 1e-7) { print($0) }
    try tuned.write(to: out)
    print(String(format: "round %d: error %.6f -> %.6f after %d epochs, %@; weights written to %@",
                 tuned.round, report.lossBefore, report.lossAfter, report.epochs, elapsed(), out.path))

case "compare":
    guard let candidate = inputs.first else { fail("compare needs a weights file") }
    let games = option("--games").flatMap(Int.init) ?? 100
    var tested = weights(candidate)
    let baseline = weights(option("--against"))
    let depth = option("--depth").flatMap(Int.init) ?? 4
    let tally = Training.compare(
        tested, against: baseline, games: games, depth: depth, seed: option("--seed").flatMap(UInt64.init) ?? 1
    ) { done in
        if done % max(1, games / 10) == 0 { print("\(done)/\(games) games, \(elapsed())") }
    }
    let elo = tally.eloDifference.map { String(format: "%+.0f", $0 + 0) } ?? "n/a"  // + 0: no "-0"
    let summary = String(format: "+%d =%d -%d, score %.1f%%, Elo difference %@", tally.wins, tally.draws, tally.losses,
                         tally.score * 100, elo)
    print(summary)
    if args.contains("--record") {
        guard !candidate.hasPrefix("round:") else { fail("--record writes to the candidate's file; round:N is read-only") }
        tested.note += " Against round \(baseline.round), \(games) games at depth \(depth): \(summary)."
        try tested.write(to: URL(fileURLWithPath: candidate))
        print("recorded in \(candidate)")
    }

case "rounds":
    for round in EvalWeights.bundledRounds {
        let w = try EvalWeights.bundled(round: round)
        print("round \(w.round): \(w.positions) positions. \(w.note)")
    }

case "book":
    let files = inputs
    guard !files.isEmpty else { fail("give one or more opening files (TSV with a pgn column)") }
    let out = output()
    let plies = option("--plies").flatMap(Int.init) ?? 16
    let margin = option("--margin").flatMap(Int.init) ?? 50
    let depth = option("--depth").flatMap(Int.init) ?? 14
    let lines = try files.flatMap { OpeningBook.lines(fromTSV: try String(contentsOfFile: $0, encoding: .utf8)) }
    guard !lines.isEmpty else { fail("no opening lines found: each file needs a header with a pgn column") }
    let engine: any AnalysisEngine
    switch option("--engine") ?? "stockfish" {
    case "stockfish":
        guard let stockfish = try? StockfishEngine() else { fail("Stockfish not found: install it, or pass --engine chesssearch") }
        engine = stockfish
    case "chesssearch": engine = SearchEngine(hashMB: 64)
    default: fail("--engine is stockfish or chesssearch")
    }
    try await engine.start()
    print("\(lines.count) opening lines; checking each position with \(engine.name) at depth \(depth)")
    let book = try await OpeningBook.build(
        lines: lines, plies: plies, marginCp: margin, engine: engine, limits: EngineLimits(depth: depth, movetimeMs: 5_000)
    ) { done, total in
        if done % 500 == 0 || done == total { print("\(done)/\(total) positions, \(elapsed())"); fflush(stdout) }
    }
    await engine.shutdown()
    let header = [
        "Opening book for ChessSearch, built by chessai-train book from \(lines.count) opening lines.",
        "Moves within \(margin) cp of \(engine.name)'s best at depth \(depth) (at most 5 s each), up to ply \(plies). Weight: lines that play it.",
    ]
    try book.text(header: header).write(to: out, atomically: true, encoding: .utf8)
    print("\(book.count) positions written to \(out.path)")

default:
    print("""
    usage:
      chessai-train selfplay --games N [--depth D] [--random-plies P] [--weights W] [--seed S] --out POSITIONS
      chessai-train pgn GAMES.pgn... --out POSITIONS
      chessai-train tune POSITIONS... [--from W] [--epochs E] [--rate R] [--regularization L] --out W.json
      chessai-train compare W [--against W] [--games N] [--depth D] [--record]
      chessai-train rounds
      chessai-train book OPENINGS.tsv... [--plies P] [--margin CP] [--depth D] [--engine stockfish|chesssearch] --out BOOK
    W is a weights file or round:N (bundled with the engine; round:0 is the standard values).
    """)
    exit(args.isEmpty ? 0 : 1)
}
