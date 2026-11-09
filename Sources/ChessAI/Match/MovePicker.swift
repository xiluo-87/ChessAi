import Foundation
import ChessCore
import ChessEngine

/// How the persona plays, and how much model time it may spend.
public struct PlaySettings: Codable, Sendable, Hashable {
    /// Search depth of the candidate search: the strength knob (8 is club level, 18 is very strong).
    public var engineDepth: Int
    /// How many engine lines are considered.
    public var candidates: Int
    /// A line counts as a candidate when it is at most this far below the best one.
    public var marginCp: Int
    /// When the best line leads the second by this much, it is played without asking the model.
    public var obviousGapCp: Int
    /// The strong model is asked at most this often per game; beyond that the engine's best line is played.
    public var maxModelCalls: Int
    /// Positions before this ply are played from the repertoire or by the engine alone.
    public var thinkFromPly: Int

    public init(
        engineDepth: Int = 14, candidates: Int = 4, marginCp: Int = 60, obviousGapCp: Int = 150,
        maxModelCalls: Int = 25, thinkFromPly: Int = 4
    ) {
        self.engineDepth = engineDepth
        self.candidates = candidates
        self.marginCp = marginCp
        self.obviousGapCp = obviousGapCp
        self.maxModelCalls = maxModelCalls
        self.thinkFromPly = thinkFromPly
    }
}

public struct Candidate: Sendable, Hashable {
    public var move: Move
    public var san: String
    /// From the persona's side.
    public var score: EngineScore
    public var line: [String]
}

public struct MoveDecision: Sendable {
    public var move: Move
    public var source: MoveSource
    public var reason: String?
    public var candidates: [Candidate]
    /// The position's evaluation from White's side, when the engine ran.
    public var evalWhite: Int?

    /// The engine's top move, when the model chose a different one.
    public var engineTop: String? {
        guard source == .model, let top = candidates.first, top.move != move else { return nil }
        return top.san
    }
}

/// Chooses the persona's moves. Free sources come first (forced move, repertoire, a clearly best engine line); the
/// strong model is asked only when several sound moves remain, and only up to the game's call budget.
public actor MovePicker {
    private let router: ModelRouter
    private let engine: any AnalysisEngine
    private let settings: PlaySettings
    private let persona: PersonaProfile
    private let context: MatchContext
    /// Tested opening moves for an engine that plays openings poorly on its own; nil plays the engine from move one.
    private let book: OpeningBook?
    /// The same text for the whole game, so the provider's prompt cache serves every call after the first.
    private let system: String
    private var plan = ""
    public private(set) var modelCalls = 0

    public init(
        router: ModelRouter, engine: any AnalysisEngine, settings: PlaySettings, persona: PersonaProfile,
        dossier: OpponentDossier?, context: MatchContext, book: OpeningBook? = nil
    ) {
        self.router = router
        self.engine = engine
        self.book = book
        self.settings = settings
        self.persona = persona
        self.context = context
        // A dossier from another match (or a human's in PvP) never reaches the prompt.
        let usable = dossier.flatMap { context.mayRead($0.opponent) ? $0 : nil }
        self.system = Prompts.matchSystem(persona: persona, dossier: usable, context: context)
    }

    /// `allowModel: false` (a short clock) plays the engine's best line instead of asking the model.
    public func choose(in game: Game, allowModel: Bool = true) async throws -> MoveDecision {
        let position = game.current
        let legal = position.legalMoves()
        guard let only = legal.first else { throw EngineError.noResponse("no legal move") }
        if legal.count == 1 {
            return MoveDecision(move: only, source: .forced, reason: "only legal move", candidates: [], evalWhite: nil)
        }
        if let book = bookMove(in: game) { return book }
        if let move = book?.pick(at: position) {
            return MoveDecision(move: move, source: .book, reason: "opening book", candidates: [], evalWhite: nil)
        }

        let lines = try await engine.analyse(
            fen: game.startPosition.fen, moves: game.moves.map(\.uci), multiPV: settings.candidates, limits: EngineLimits(depth: settings.engineDepth))
        let candidates = lines.compactMap { line -> Candidate? in
            guard let move = Move(uci: line.move), position.isLegal(move) else { return nil }
            return Candidate(move: move, san: position.san(for: move), score: line.score, line: Self.sanLine(line.pv, from: position))
        }
        guard let best = candidates.first else {
            return MoveDecision(move: only, source: .engine, reason: "engine gave no line", candidates: [], evalWhite: nil)
        }
        let evalWhite = position.sideToMove == .white ? best.score.normalized : -best.score.normalized
        func engineChoice(_ reason: String) -> MoveDecision {
            MoveDecision(move: best.move, source: .engine, reason: reason, candidates: candidates, evalWhite: evalWhite)
        }

        let sound = candidates.filter { best.score.normalized - $0.score.normalized <= settings.marginCp }
        if sound.count < 2 {
            let gap = candidates.count > 1 ? best.score.normalized - candidates[1].score.normalized : 0
            return engineChoice(gap >= settings.obviousGapCp ? "clearly best move" : "the only sound move")
        }
        if game.moves.count < settings.thinkFromPly { return engineChoice("early opening") }
        if !allowModel { return engineChoice("short on time") }
        if modelCalls >= settings.maxModelCalls { return engineChoice("model budget for this game used up") }
        if modelCalls >= Self.pacedBudget(settings.maxModelCalls, ply: game.moves.count) {
            return engineChoice("saving model calls for later")
        }
        // Near-equal moves in a quiet position are a matter of taste the engine settles as well as the model.
        if sound.count >= 2, best.score.normalized - sound[sound.count - 1].score.normalized <= 15,
           !position.isInCheck(), GamePhase.of(position, ply: game.moves.count) == .opening {
            return engineChoice("equal developing moves")
        }

        modelCalls += 1
        do {
            let reply = try await router.call(
                Prompts.moveRequest(system: system, game: game, candidates: sound, plan: plan, context: context),
                tier: .strong, purpose: "move \(game.moves.count / 2 + 1)")
            let answer = (reply.json["move"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let reason = reply.json["reason"] as? String
            if let next = reply.json["plan"] as? String { plan = String(next.prefix(140)) }
            let picked = sound.first { $0.san == answer || $0.move.uci == answer }
                ?? position.move(fromSAN: answer).flatMap { move in sound.first { $0.move == move } }
            guard let picked else { return engineChoice("model named \(answer), not a candidate") }
            return MoveDecision(move: picked.move, source: .model, reason: reason, candidates: candidates, evalWhite: evalWhite)
        } catch {
            return engineChoice("model unavailable: \(error.localizedDescription)")
        }
    }

    /// The next move of a repertoire line the game still follows, most confident line first.
    private func bookMove(in game: Game) -> MoveDecision? {
        guard game.startPosition == .start else { return nil }
        for note in persona.repertoire(for: context.personaColor) {
            let line = note.line ?? []
            guard line.count > game.sans.count,
                  zip(game.sans, line).allSatisfy({ Self.bare($0) == Self.bare($1) }),
                  let move = game.current.move(fromSAN: line[game.sans.count]) else { continue }
            return MoveDecision(move: move, source: .book, reason: "repertoire: \(note.statement)", candidates: [], evalWhite: nil)
        }
        return nil
    }

    /// The calls usable by this ply: a quarter of the budget at the start, all of it by ply 80, so the middlegame,
    /// where choices matter most, is not left without any.
    static func pacedBudget(_ budget: Int, ply: Int) -> Int {
        Int((Double(budget) * min(1, 0.25 + Double(ply) / 80 * 0.75)).rounded(.up))
    }

    static func bare(_ san: String) -> String { san.filter { !"+#!?".contains($0) } }

    static func sanLine(_ pv: [String], from position: Position, plies: Int = 4) -> [String] {
        var position = position
        var sans: [String] = []
        for uci in pv.prefix(plies) {
            guard let move = Move(uci: uci), position.isLegal(move) else { break }
            sans.append(position.san(for: move))
            position = position.applying(move)
        }
        return sans
    }
}
