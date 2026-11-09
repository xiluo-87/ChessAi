import Foundation
import SwiftUI
import ChessCore
import ChessEngine
import ChessAI
import ChessSearch

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

/// Settings ▸ Stockfish Match keeps these in UserDefaults; the New Game menu starts the match with them.
enum MatchDefaults {
    static let depthKey = "engineMatch.depth"
    static let whiteKey = "engineMatch.white"
}

/// Settings ▸ Engine: which engine finds the persona's candidates and reviews its games.
enum EngineChoice: String, CaseIterable, Identifiable {
    case stockfish, chessSearch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stockfish: "Stockfish"
        case .chessSearch: "ChessSearch (our own)"
        }
    }
}

enum EngineDefaults {
    static let key = "engine.choice"
    /// ChessSearch is far slower to a given depth than Stockfish, and the callers ask for depths: this keeps its moves
    /// within a Lichess clock whatever the Strength setting says.
    static let chessSearchMoveTimeMs = 2_000

    static var choice: EngineChoice {
        UserDefaults.standard.string(forKey: key).flatMap(EngineChoice.init(rawValue:)) ?? .stockfish
    }
}

/// Settings ▸ General: whether finished games are saved as training data for ChessSearch's evaluation.
enum TrainingDefaults {
    static let saveGamesKey = "training.saveGames"
}

enum Phase: Equatable {
    case idle
    case playing
    case personaThinking
    case reviewing
    case finished
    /// A Lichess game is on the board: nobody here moves on it.
    case watching
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
    @Published var status = "Starting the engine…"
    /// The persona's score per arena, counted from the saved games.
    @Published private(set) var offlineScore = Record()
    @Published private(set) var lichessScore = Record()
    /// Published so the New Game buttons enable once the engine is up.
    @Published private(set) var engineReady = false
    @Published var error: String?

    let store = MemoryStore()
    let router: ModelRouter
    private var engine: (any AnalysisEngine)?
    /// Each engine stays up once started: a game or the Lichess bot may still be using the one switched away from.
    private var engines: [EngineChoice: any AnalysisEngine] = [:]
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
        refreshScores()
        Task { await useSelectedEngine() }
    }

    func refreshScores() {
        var offline = Record(), online = Record()
        for game in store.games(persona: persona.id) {
            if game.opponent.isLichess { online.add(game.result, as: game.personaColor) }
            else if game.opponent.isHuman { offline.add(game.result, as: game.personaColor) }
        }
        offlineScore = offline
        lichessScore = online
    }

    var personaColor: PieceColor { humanColor.opposite }
    /// The persona's reasons and candidates are shown in PvP and engine matches; in single player only the moves.
    var showThoughts: Bool { boardIsExternal || engineMatch != nil || context?.mode == .pvp }
    /// The persona's side on the board shown: in watched games (Lichess, engine match) it sits at the bottom.
    var personaSide: PieceColor { boardIsExternal ? humanColor : personaColor }
    var bottomColor: PieceColor { boardIsExternal || engineMatch != nil ? personaSide : humanColor }
    var engineInstance: (any AnalysisEngine)? { engine }
    /// ChessSearch's opening book, loaded once; nil when the app was built without one.
    private static let chessSearchBook = OpeningBook.bundled()
    /// The book for an engine: ChessSearch plays openings poorly without one, Stockfish needs none.
    func book(for engine: any AnalysisEngine) -> OpeningBook? {
        engine is SearchEngine ? Self.chessSearchBook : nil
    }
    private(set) lazy var lichess = LichessController(app: self)

    /// Games and the Lichess bot started from now on use the engine chosen in Settings; running ones keep theirs.
    func useSelectedEngine() async {
        let choice = EngineDefaults.choice
        do {
            let selected: any AnalysisEngine
            if let running = engines[choice] {
                selected = running
            } else {
                engineReady = false
                switch choice {
                case .stockfish: selected = try StockfishEngine()
                case .chessSearch: selected = SearchEngine(maxMoveTimeMs: EngineDefaults.chessSearchMoveTimeMs)
                }
                try await selected.start()
                engines[choice] = selected
            }
            guard choice == EngineDefaults.choice else { return }  // switched again meanwhile: that call decides
            engine = selected
            engineReady = true
            if phase == .idle { status = "Start a new game." }
        } catch {
            guard choice == EngineDefaults.choice else { return }
            engine = nil
            self.error = "Stockfish could not start (\(error)). Install it with: brew install stockfish, or choose ChessSearch in Settings ▸ Engine."
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
        guard let engine else { error = "The engine is not running."; return }
        do {
            let opponent = OpponentID.human(settings.playerName)
            let context = try MatchContext(mode: .singlePlayer, personaID: persona.id, opponent: opponent, personaColor: color.opposite)
            let dossier = store.dossier(opponent, persona: persona.id, in: context)
            self.context = context
            self.dossier = dossier
            picker = MovePicker(
                router: router, engine: engine, settings: settings.play, persona: persona, dossier: dossier, context: context,
                book: book(for: engine))
            stopEngineMatch()
            engineMatch = nil
            humanColor = color
            boardIsExternal = false
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
                    reason: decision.reason, evalBefore: decision.evalWhite, engineTop: decision.engineTop))
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
        saveTrainingData(fen: game.startPosition.fen, moves: game.moves.map(\.uci), result: game.result)
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
            refreshScores()
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

    // MARK: Engine match

    /// A watched game at equal engine strength: plain Stockfish plays its best move at depth N; the persona gets
    /// Stockfish's candidates at the same depth N and its model picks among them. Nothing is counted, reviewed or stored.
    struct EngineMatch: Equatable {
        var label: String
    }

    @Published private(set) var engineMatch: EngineMatch?
    private var opponentEngine: StockfishEngine?
    private var matchTask: Task<Void, Never>?

    func startEngineMatch(personaPlays color: PieceColor, depth: Int) {
        guard let engine, phase != .watching else { return }
        stopEngineMatch()
        let label = "Stockfish depth \(depth)"
        do {
            let context = try MatchContext(mode: .pvp, personaID: persona.id, opponent: .model(label), personaColor: color)
            var play = settings.play
            play.engineDepth = depth
            // Reads its memory like any game (own notes, and its notes on this opponent if it has any); it writes nothing.
            let dossier = store.dossier(context.opponent, persona: persona.id, in: context)
            let picker = MovePicker(
                router: router, engine: engine, settings: play, persona: persona, dossier: dossier, context: context,
                book: book(for: engine))
            self.context = nil
            self.picker = nil
            humanColor = color.opposite  // the engine's side; personaColor is then the persona's
            boardIsExternal = false
            engineMatch = EngineMatch(label: label)
            game = Game()
            notes = []
            lastCandidates = []
            lastRecord = nil
            gameStart = Date()
            gameCalls = []
            phase = .watching
            status = "\(persona.name) vs \(label)"
            matchTask = Task { await runEngineMatch(picker: picker, persona: color, depth: depth, label: label) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stopEngineMatch() {
        guard matchTask != nil || engineMatch != nil else { return }
        matchTask?.cancel()
        matchTask = nil
        if phase == .watching, engineMatch != nil {
            phase = .finished
            status = "Match stopped."
        }
    }

    /// With the side and depth from Settings ▸ Stockfish Match.
    func startEngineMatch() {
        let defaults = UserDefaults.standard
        let white = defaults.object(forKey: MatchDefaults.whiteKey) as? Bool ?? true
        startEngineMatch(personaPlays: white ? .white : .black, depth: defaults.object(forKey: MatchDefaults.depthKey) as? Int ?? 10)
    }

    // MARK: What the toolbar and menus may do now

    var canStartGame: Bool { engineReady && !(phase == .watching && engineMatch == nil) }
    var canStartEngineMatch: Bool { engineReady && phase != .watching && phase != .personaThinking }
    var canResign: Bool { phase == .playing || phase == .personaThinking }
    var engineMatchRunning: Bool { engineMatch != nil && phase == .watching }

    private func runEngineMatch(picker: MovePicker, persona color: PieceColor, depth: Int, label: String) async {
        do {
            let opponent: StockfishEngine
            if let existing = opponentEngine {
                opponent = existing
            } else {
                // The same threads and hash as the persona's engine, so equal depth means equal strength.
                opponent = try StockfishEngine()
                try await opponent.start()
                opponentEngine = opponent
            }
            try await opponent.newGame()

            while !Task.isCancelled, game.result == .ongoing, game.moves.count < 400 {
                let snapshot = game
                if snapshot.current.sideToMove == color {
                    status = "\(persona.name) is thinking…"
                    let decision = try await picker.choose(in: snapshot)
                    guard !Task.isCancelled, game.moves == snapshot.moves else { return }
                    notes.append(MoveNote(
                        ply: notes.count, san: snapshot.current.san(for: decision.move), byPersona: true,
                        source: decision.source, reason: decision.reason, evalBefore: decision.evalWhite,
                        engineTop: decision.engineTop))
                    game.play(decision.move)
                    lastCandidates = decision.candidates
                    gameCalls = await router.records(since: gameStart)
                } else {
                    status = "\(label) is thinking…"
                    guard let uci = try await opponent.bestMove(fen: snapshot.startPosition.fen, moves: snapshot.moves.map(\.uci), limits: EngineLimits(depth: depth)),
                          let move = Move(uci: uci), snapshot.current.isLegal(move) else { break }
                    // A short pause so the engine's instant replies stay watchable.
                    try await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, game.moves == snapshot.moves else { return }
                    notes.append(MoveNote(ply: notes.count, san: snapshot.current.san(for: move), byPersona: false))
                    game.play(move)
                }
            }
            guard !Task.isCancelled else { return }
            phase = .finished
            saveTrainingData(fen: game.startPosition.fen, moves: game.moves.map(\.uci), result: game.result)
            let outcome = game.end.map { " by \($0.rawValue)" } ?? (game.moves.count >= 400 ? " (move limit)" : "")
            status = "\(persona.name) vs \(label): \(game.result.rawValue)\(outcome). Not counted or reviewed."
        } catch is CancellationError {
        } catch {
            self.error = "The engine match stopped: \(error.localizedDescription)"
            phase = .finished
        }
        matchTask = nil
    }

    // MARK: Lichess

    /// Mirrors a Lichess game onto the board (the persona's side at the bottom).
    /// The board holds a Lichess game (live or just finished) rather than a local one.
    @Published private(set) var boardIsExternal = false

    func showExternal(game: Game, notes: [MoveNote], personaColor: PieceColor, status: String) {
        stopEngineMatch()
        engineMatch = nil
        boardIsExternal = true
        if phase != .watching {
            context = nil
            picker = nil
            lastRecord = nil
            lastCandidates = []
            gameCalls = []
            gameStart = Date()
        }
        refreshCalls()
        self.game = game
        self.notes = notes
        humanColor = personaColor  // board orientation only: the persona sits at the bottom
        phase = .watching
        self.status = status
    }

    func externalReviewing(result: GameResult) {
        phase = .reviewing
        status = "Lichess game over (\(result.rawValue)). \(persona.name) is reviewing the game and updating its notes…"
    }

    func endExternal(record: GameRecord?) {
        if phase == .watching || phase == .reviewing { phase = .finished }
        if let record, record.review == nil {
            status = "Lichess game over (\(record.result.rawValue)): too short to review, so the notes stay as they were."
        } else if record == nil {
            status = "Lichess game aborted."
        }
    }

    func personaUpdated(_ persona: PersonaProfile) { self.persona = persona }

    /// The Lichess bot makes its model calls outside this class, so the panel reads them from the shared ledger.
    private func refreshCalls() {
        let since = gameStart
        Task { self.gameCalls = await self.router.records(since: since) }
    }

    func showRecord(_ record: GameRecord) {
        refreshCalls()
        lastRecord = record
        status = "Lichess game over (\(record.result.rawValue)). \(persona.name) updated its notes."
    }

    // MARK: Training data

    /// Finished games' quiet positions and results, for `chessai-train tune`.
    var trainingFile: URL { store.root.appendingPathComponent("training/games.txt") }

    /// Appends a finished game's positions to `trainingFile` (unless turned off in Settings); unfinished games add
    /// nothing. The weights change only when a new round is tuned from the file and kept.
    func saveTrainingData(fen: String, moves: [String], result: GameResult) {
        saveTraining(Training.positions(fen: fen, moves: moves, result: result))
    }

    /// For Lichess games, whose record knows endings (time, resignation) the moves alone do not.
    func saveTrainingData(pgn: String, result: GameResult) {
        saveTraining(Training.positions(fromPGN: pgn, result: result))
    }

    private func saveTraining(_ positions: [TrainingPosition]) {
        guard UserDefaults.standard.object(forKey: TrainingDefaults.saveGamesKey) as? Bool ?? true, !positions.isEmpty else { return }
        do {
            try Training.append(positions, to: trainingFile)
        } catch {
            status += " (training data not saved: \(error.localizedDescription))"
        }
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
