import Foundation
import ChessSearch

// chessai-train: tune ChessSearch's evaluation against game results.
//
//   chessai-train selfplay --games N [--depth D] [--random-plies P] [--weights W.json] [--seed S] --out POSITIONS
//   chessai-train pgn GAMES.pgn... --out POSITIONS
//   chessai-train tune POSITIONS... [--from W.json] [--epochs E] [--rate R] [--regularization L] --out W.json
//   chessai-train compare W.json [--against W.json] [--games N] [--depth D]
//
// A typical round: self-play (or a PGN), tune, then compare the tuned weights with the ones they started from.
// Load the result with SearchEngine(weights: try EvalWeights(contentsOf: url)).

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Arguments that are neither options nor their values.
var inputs: [String] {
    var out: [String] = []
    var i = 1
    while i < args.count {
        if args[i].hasPrefix("--") { i += 2 } else { out.append(args[i]); i += 1 }
    }
    return out
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func weights(_ path: String?) -> EvalWeights {
    guard let path else { return .standard }
    do { return try EvalWeights(contentsOf: URL(fileURLWithPath: path)) } catch { fail("cannot read weights \(path): \(error)") }
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
    print(String(format: "error %.6f -> %.6f after %d epochs, %@; weights written to %@",
                 report.lossBefore, report.lossAfter, report.epochs, elapsed(), out.path))

case "compare":
    guard let candidate = inputs.first else { fail("compare needs a weights file") }
    let games = option("--games").flatMap(Int.init) ?? 100
    let tally = Training.compare(
        weights(candidate), against: weights(option("--against")), games: games,
        depth: option("--depth").flatMap(Int.init) ?? 4, seed: option("--seed").flatMap(UInt64.init) ?? 1
    ) { done in
        if done % max(1, games / 10) == 0 { print("\(done)/\(games) games, \(elapsed())") }
    }
    let elo = tally.eloDifference.map { String(format: "%+.0f", $0) } ?? "n/a"
    print(String(format: "+%d =%d -%d, score %.1f%%, Elo difference %@", tally.wins, tally.draws, tally.losses,
                 tally.score * 100, elo))

default:
    print("""
    usage:
      chessai-train selfplay --games N [--depth D] [--random-plies P] [--weights W.json] [--seed S] --out POSITIONS
      chessai-train pgn GAMES.pgn... --out POSITIONS
      chessai-train tune POSITIONS... [--from W.json] [--epochs E] [--rate R] [--regularization L] --out W.json
      chessai-train compare W.json [--against W.json] [--games N] [--depth D]
    """)
    exit(args.isEmpty ? 0 : 1)
}
