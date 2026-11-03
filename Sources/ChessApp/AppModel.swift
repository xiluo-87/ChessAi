import Foundation
import SwiftUI
import ChessCore
import ChessEngine
import ChessAI

/// Settings kept in UserDefaults as one JSON value.
struct AppSettings: Codable, Equatable {
    var routing = ModelRouting.default
    var play = PlaySettings()
    var playerName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Player"
    var personaID = MemoryStore.defaultPersona.id

    static let key = "settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum Phase: Equatable {
    case idle
    case playing
    case personaThinking
    case reviewing
    case finished
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { settingsChanged(oldValue) } }
    @Published private(set) var game = Game()
    @Published private(set) var notes: [MoveNote] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var humanColor: PieceColor = .white
    @Published private(set) var persona: PersonaProfile
    @Published private(set) var dossier: OpponentDossier?
    @Published private(set) var lastRecord: GameRecord?
    @Published private(set) var gameCalls: [CallRecord] = []
    @Published private(set) var lastCandidates: [Candidate] = []
    @Published var status = "Starting Stockfish…"
    /// Published so the New Game buttons enable once the engine is up.
    @Published private(set) var engineReady = false
    @Published var error: String?

    let store = MemoryStore()
    let router: ModelRouter
    private var engine: StockfishEngine?
    private var picker: MovePicker?
    private var context: MatchContext?
    private var gameStart = Date()
    private var gameID = ""

    init() {
        var settings = AppSettings.load()
        if settings.personaID == "kasia" { settings.personaID = MemoryStore.defaultPersona.id }
        self.settings = settings
        router = ModelRouter(routing: settings.routing)
        let store = self.store
        store.migrateLegacyPersona()
        if store.persona(settings.personaID) == nil { try? store.save(MemoryStore.defaultPersona) }
        persona = store.persona(settings.personaID) ?? MemoryStore.defaultPersona
        Task { await startEngine() }
    }

    var personaColor: PieceColor { humanColor.opposite }
    /// The persona's reasons and candidates are shown in PvP only; in single player you see just the moves.
    var showThoughts: Bool { context?.mode == .pvp }

    private func startEngine() async {
        do {
            let engine = try StockfishEngine()
            try await engine.start()
            self.engine = engine
            engineReady = true
            if phase == .idle { status = "Start a new game." }
        } catch {
            self.error = "Stockfish could not start (\(error)). Install it with: brew install stockfish"
        }
    }

    private func settingsChanged(_ old: AppSettings) {
        guard settings != old else { return }
        settings.save()
        let routing = settings.routing
        Task { await router.update(routing) }
        if settings.personaID != old.personaID, let p = store.persona(settings.personaID) { persona = p }
    }

    // MARK: Game flow

    func newGame(humanPlays color: PieceColor) {
        guard let engine else { error = "Stockfish is not running."; return }
        do {
            let opponent = OpponentID.human(settings.playerName)
            let context = try MatchContext(mode: .singlePlayer, personaID: persona.id, opponent: opponent, personaColor: color.opposite)
            let dossier = store.dossier(opponent, persona: persona.id, in: context)
            self.context = context
            self.dossier = dossier
            picker = MovePicker(router: router, engine: engine, settings: settings.play, persona: persona, dossier: dossier, context: context)
            humanColor = color
            game = Game()
            notes = []
            lastCandidates = []
            lastRecord = nil
            gameCalls = []
            gameStart = Date()
            gameID = Self.gameID()
            phase = .playing
            status = "Your move."
            Task { try? await engine.newGame() }
            if game.current.sideToMove == personaColor { personaMove() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func humanMove(_ move: Move) {
        guard phase == .playing, game.current.sideToMove == humanColor, game.current.isLegal(move) else { return }
        let san = game.current.san(for: move)
        game.play(move)
        notes.append(MoveNote(ply: notes.count, san: san, byPersona: false))
        if !checkEnd() { personaMove() }
    }

    func resign() {
        guard phase == .playing || phase == .personaThinking else { return }
        game.resign(humanColor)
        _ = checkEnd()
    }

    private func personaMove() {
        guard let picker else { return }
        phase = .personaThinking
        status = "\(persona.name) is thinking…"
        let snapshot = game
        Task {
            do {
                let decision = try await picker.choose(in: snapshot)
                guard self.phase == .personaThinking, self.game.moves == snapshot.moves else { return }
                let san = self.game.current.san(for: decision.move)
                self.game.play(decision.move)
                self.notes.append(MoveNote(
                    ply: self.notes.count, san: san, byPersona: true, source: decision.source,
                    reason: decision.reason, evalBefore: decision.evalWhite))
                self.lastCandidates = decision.candidates
                self.gameCalls = await self.router.records(since: self.gameStart)
                if !self.checkEnd() {
                    self.phase = .playing
                    self.status = "Your move."
                }
            } catch {
                self.error = "The persona could not move: \(error.localizedDescription)"
                self.phase = .playing
            }
        }
    }

    /// Ends the game when it is over and starts the review. Returns true when the game ended.
    private func checkEnd() -> Bool {
        guard game.result != .ongoing else { return false }
        phase = .reviewing
        status = "Game over (\(game.result.rawValue)). \(persona.name) is reviewing the game…"
        Task { await finish() }
        return true
    }

    private func finish() async {
        guard let engine, let context else { return }
        let modelUsage = await router.totals(since: gameStart)
        let calls = await router.records(since: gameStart).count
        var record = GameRecord(
            id: gameID, date: gameStart, personaID: persona.id, opponent: context.opponent,
            personaColor: personaColor, result: game.result, end: game.end,
            pgn: game.pgn(tags: pgnTags()), notes: notes, usage: modelUsage, calls: calls)
        do {
            let review = try await GameReviewer(engine: engine).review(game, personaColor: personaColor)
            record.review = review
            let outcome = try await MemoryUpdater(router: router, store: store)
                .update(record: record, review: review, persona: persona, context: context)
            record = outcome.record
            persona = outcome.persona
            dossier = outcome.dossier
            record.usage = await router.totals(since: gameStart)
            record.calls = await router.records(since: gameStart).count
            try store.save(record)
            status = "Game over (\(game.result.rawValue)). \(persona.name) updated its notes."
        } catch {
            try? store.save(record)
            self.error = "The review could not finish: \(error.localizedDescription). The game was saved."
            status = "Game over (\(game.result.rawValue))."
        }
        gameCalls = await router.records(since: gameStart)
        lastRecord = record
        phase = .finished
    }

    private func pgnTags() -> [(String, String)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let human = settings.playerName, ai = persona.name
        return [
            ("Event", "ChessAi casual game"), ("Site", "ChessAi"), ("Date", formatter.string(from: gameStart)),
            ("Round", "-"), ("White", humanColor == .white ? human : ai), ("Black", humanColor == .black ? human : ai),
            ("Result", game.result.rawValue),
        ]
    }

    private static func gameID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: Memory

    func resetPersonaMemory() {
        var fresh = persona
        fresh.notes = []
        fresh.record = Record()
        try? store.save(fresh)
        persona = fresh
    }
}
