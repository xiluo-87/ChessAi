import Foundation
import ChessCore
import ChessEngine
import ChessAI

// chessai-cli selfplay [--plies N] [--store DIR] [--strong MODEL] [--cheap MODEL] [--sparring-depth D]
//
// The persona plays a weakened Stockfish ("sparring", standing in for the human player) with real model calls,
// then reviews the game and rewrites its memory. Prints each move with its source and reason, and the cost.

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let maxPlies = Int(argument("--plies") ?? "") ?? 60
let storeURL = URL(fileURLWithPath: argument("--store") ?? NSTemporaryDirectory() + "chessai-selfplay")
let routing = ModelRouting(
    strong: ModelSpec(backend: .claudeCLI, model: argument("--strong") ?? "sonnet", effort: "low"),
    cheap: ModelSpec(backend: .claudeCLI, model: argument("--cheap") ?? "haiku"))
let sparringDepth = Int(argument("--sparring-depth") ?? "") ?? 3

let store = MemoryStore(root: storeURL)
if store.persona(MemoryStore.defaultPersona.id) == nil { try store.save(MemoryStore.defaultPersona) }
let persona = store.persona(MemoryStore.defaultPersona.id)!
let router = ModelRouter(routing: routing)
let engine = try StockfishEngine()
try await engine.start()
let sparring = try StockfishEngine()
try await sparring.start()
try await sparring.setOption(name: "Skill Level", value: "0")

let context = try MatchContext(mode: .singlePlayer, personaID: persona.id, opponent: .human("Sparring"), personaColor: .white)
let dossier = store.dossier(context.opponent, persona: persona.id, in: context)
let picker = MovePicker(
    router: router, engine: engine, settings: PlaySettings(engineDepth: 12, maxModelCalls: 8), persona: persona,
    dossier: dossier, context: context)

print("Store: \(storeURL.path)\nPersona: \(persona.name), \(persona.notes.count) notes; strong \(routing.strong.label), cheap \(routing.cheap.label)\n")
var game = Game()
var notes: [MoveNote] = []
while game.result == .ongoing && game.moves.count < maxPlies {
    let san: String
    if game.current.sideToMove == context.personaColor {
        let decision = try await picker.choose(in: game)
        san = game.current.san(for: decision.move)
        notes.append(MoveNote(ply: notes.count, san: san, byPersona: true, source: decision.source, reason: decision.reason, evalBefore: decision.evalWhite))
        game.play(decision.move)
        print("\(notes.count / 2 + notes.count % 2). \(san)  [\(decision.source.rawValue)] \(decision.reason ?? "")")
    } else {
        guard let uci = try await sparring.bestMove(fen: game.current.fen, limits: EngineLimits(depth: sparringDepth)),
              let move = Move(uci: uci) else { break }
        san = game.current.san(for: move)
        notes.append(MoveNote(ply: notes.count, san: san, byPersona: false))
        game.play(move)
        print("   … \(san)")
    }
}
if game.result == .ongoing { game.resign(.black) }  // a cut-off game counts as the sparring partner's loss
print("\nResult: \(game.result.rawValue) \(game.end?.rawValue ?? "")")

var record = GameRecord(
    id: "selfplay-\(Int(Date().timeIntervalSince1970))", date: Date(), personaID: persona.id, opponent: context.opponent,
    personaColor: context.personaColor, result: game.result, end: game.end, pgn: game.pgn(tags: []), notes: notes)
let review = try await GameReviewer(engine: engine).review(game, personaColor: context.personaColor)
print("Review: persona avg loss \(review.persona.averageLoss) cp, sparring \(review.opponent.averageLoss) cp")
let outcome = try await MemoryUpdater(router: router, store: store)
    .update(record: record, review: review, persona: persona, context: context)
record = outcome.record

print("\nSummary: \(record.summary ?? "-")\n\nPersona notes:\n\(NoteRenderer.render(outcome.persona.notes))")
print("\nNotes on the opponent:\n\(NoteRenderer.render(outcome.dossier?.notes ?? []))")
let calls = await router.records()
let total = calls.reduce(ModelUsage()) { $0 + $1.usage }
print("\nCalls: \(calls.count) (\(calls.filter { $0.tier == .strong }.count) strong); tokens in \(total.inputTokens), cached \(total.cachedTokens), out \(total.outputTokens); list price $\(String(format: "%.4f", total.costUSD ?? 0))")
for call in calls { print("  \(call.tier.rawValue) \(call.model) \(call.purpose): \(String(format: "%.1f", call.seconds)) s, $\(String(format: "%.4f", call.usage.costUSD ?? 0))") }
await engine.shutdown()
await sparring.shutdown()
