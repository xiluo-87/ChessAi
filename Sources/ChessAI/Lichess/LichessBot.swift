import Foundation
import ChessCore
import ChessEngine

/// Which challenges the bot takes.
public struct LichessBotSettings: Codable, Sendable, Hashable {
    /// Lichess speed names the bot accepts. LLM moves take seconds, so bullet and blitz are off by default.
    public var speeds: Set<String> = ["rapid", "classical", "correspondence"]
    public var acceptRated = true
    public var acceptCasual = true
    public var acceptBots = true
    public var acceptHumans = true
    /// Said once at the start of each game; empty says nothing.
    public var greeting = "Hi! I'm JSON Bourne, an LLM persona choosing among Stockfish's candidate moves. Good luck!"

    public init() {}
}

/// What the bot reports to the app.
public enum LichessBotUpdate: Sendable {
    case status(String)
    case challenge(LichessChallenge, accepted: Bool, reason: String?)
    case gameStarted(id: String, opponent: LichessPlayer, personaColor: PieceColor, rated: Bool, speed: String)
    case position(id: String, game: Game, notes: [MoveNote], whiteMs: Int, blackMs: Int)
    /// The game is over and the persona is reviewing it into memory (takes ~20–30 s).
    case reviewing(id: String, result: GameResult)
    /// A challenge the persona sent was declined.
    case outgoingDeclined(challengeID: String)
    case gameFinished(id: String, record: GameRecord?, persona: PersonaProfile?)
    case error(String)
}

/// Plays the persona on a Lichess BOT account: takes challenges, follows each game's stream, moves with the same
/// MovePicker as the app (Stockfish candidates, the strong model picks), and reviews every finished game into memory.
public actor LichessBot {
    private let client: LichessClient
    private let account: LichessAccount
    private let engine: StockfishEngine
    private let router: ModelRouter
    private let store: MemoryStore
    private let personaID: String
    private let settings: LichessBotSettings
    private let play: PlaySettings
    private let onUpdate: @Sendable (LichessBotUpdate) -> Void
    private var eventTask: Task<Void, Never>?
    private var games: [String: Task<Void, Never>] = [:]
    /// When a challenge was last accepted: its game has not started yet, but the bot is already taken.
    private var acceptedAt: Date?

    public init(
        client: LichessClient, account: LichessAccount, engine: StockfishEngine, router: ModelRouter, store: MemoryStore,
        personaID: String, settings: LichessBotSettings, play: PlaySettings,
        onUpdate: @escaping @Sendable (LichessBotUpdate) -> Void
    ) {
        self.client = client
        self.account = account
        self.engine = engine
        self.router = router
        self.store = store
        self.personaID = personaID
        self.settings = settings
        self.play = play
        self.onUpdate = onUpdate
    }

    public var isRunning: Bool { eventTask != nil }

    /// Listens for challenges and games until `stop()`, reconnecting after a dropped stream.
    public func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var pause: Duration = .seconds(5)
                do {
                    await self.report(.status("Online as \(self.account.username), waiting for challenges."))
                    for try await event in self.client.events() { await self.handle(event) }
                } catch is CancellationError {
                    return
                } catch LichessError.rateLimited {
                    pause = .seconds(60)  // Lichess asks for a full minute after a 429
                    await self.report(.error("Rate limited by Lichess; reconnecting in a minute."))
                } catch {
                    await self.report(.error("Event stream dropped: \(error.localizedDescription). Reconnecting…"))
                }
                try? await Task.sleep(for: pause)
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        report(.status("Offline. Games in progress keep playing to the end."))
    }

    public func resign(_ gameID: String) async {
        do { try await client.resign(gameID) } catch { report(.error("Resign failed: \(error.localizedDescription)")) }
    }

    // MARK: Events

    private func handle(_ event: LichessEvent) async {
        switch event {
        case .challenge(let challenge):
            // Our own outgoing challenges arrive on the same stream; the direction field is not always present.
            guard challenge.direction != "out",
                  challenge.challenger?.id.lowercased() != account.id.lowercased() else { return }
            let reason = declineReason(challenge)
            do {
                if let reason {
                    try await client.decline(challenge.id, reason: reason)
                } else {
                    acceptedAt = Date()
                    try await client.accept(challenge.id)
                }
                report(.challenge(challenge, accepted: reason == nil, reason: reason))
            } catch {
                if reason == nil { acceptedAt = nil }
                report(.error("Challenge \(challenge.id): \(error.localizedDescription)"))
            }
        case .gameStart(let id):
            acceptedAt = nil
            guard games[id] == nil else { return }
            games[id] = Task { [weak self] in
                await self?.playGame(id)
                await self?.gameEnded(id)
            }
        case .challengeDeclined(let id):
            report(.outgoingDeclined(challengeID: id))
        default:
            break
        }
    }

    private func gameEnded(_ id: String) { games[id] = nil }

    /// Why a challenge is declined, in Lichess's reason vocabulary; nil accepts it.
    func declineReason(_ c: LichessChallenge) -> String? {
        if c.variant != "standard" { return "standard" }
        // An accepted challenge whose game never arrives must not block the bot for good.
        let awaitingGame = acceptedAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        if !games.isEmpty || awaitingGame { return "later" }
        if !settings.speeds.contains(c.speed) {
            let fast = ["ultraBullet", "bullet", "blitz"].contains(c.speed)
            return fast ? "tooFast" : "timeControl"
        }
        if c.rated && !settings.acceptRated { return "casual" }
        if !c.rated && !settings.acceptCasual { return "rated" }
        if c.challenger?.isBot == true && !settings.acceptBots { return "noBot" }
        if c.challenger?.isBot != true && !settings.acceptHumans { return "onlyBot" }
        return nil
    }

    // MARK: One game

    private struct Match {
        var id: String
        var context: MatchContext
        var opponent: LichessPlayer
        var white: LichessPlayer
        var black: LichessPlayer
        var rated: Bool
        var speed: String
        var picker: MovePicker
        var persona: PersonaProfile
        var game: Game
        var notes: [MoveNote] = []
        var started = Date()
    }

    /// Follows one game to its end. A stream that drops mid-game is reopened (Lichess starts it again with
    /// `gameFull`); the match, with the persona's notes and plan so far, carries over.
    private func playGame(_ id: String) async {
        var match: Match?
        var failures = 0
        while !Task.isCancelled && failures < 6 {
            do {
                for try await event in client.gameEvents(id) {
                    failures = 0
                    switch event {
                    case .full(_, let white, let black, let fen, let rated, let speed, let variant, let state):
                        guard variant == "standard" else {
                            try? await client.abort(id)
                            return
                        }
                        if match == nil {
                            match = try await setUp(id: id, white: white, black: black, fen: fen, rated: rated, speed: speed)
                            if state.moves.isEmpty, !settings.greeting.isEmpty {
                                try? await client.chat(id, text: settings.greeting)
                            }
                        }
                        if var m = match {
                            let done = try await advance(&m, state)
                            match = m
                            if done { return }
                        }
                    case .state(let state):
                        guard var m = match else { continue }
                        let done = try await advance(&m, state)
                        match = m
                        if done { return }
                    default:
                        continue
                    }
                }
                failures += 1  // the stream ended without the game ending
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                report(.error("Game \(id): \(error.localizedDescription). Reconnecting…"))
            }
            try? await Task.sleep(for: .seconds(failures < 3 ? 1 : 5))
        }
        report(.error("Game \(id): lost the connection for good."))
    }

    private func setUp(id: String, white: LichessPlayer, black: LichessPlayer, fen: String, rated: Bool, speed: String) async throws -> Match {
        let personaColor: PieceColor = white.id.lowercased() == account.id.lowercased() ? .white : .black
        let opponent = personaColor == .white ? black : white
        let context = try MatchContext(mode: .pvp, personaID: personaID, opponent: .lichess(opponent.name), personaColor: personaColor)
        let persona = store.persona(personaID) ?? MemoryStore.defaultPersona
        let dossier = store.dossier(context.opponent, persona: personaID, in: context)
        let start = fen == "startpos" ? Position.start : (Position(fen: fen) ?? .start)
        try? await engine.newGame()
        report(.gameStarted(id: id, opponent: opponent, personaColor: personaColor, rated: rated, speed: speed))
        return Match(
            id: id, context: context, opponent: opponent, white: white, black: black, rated: rated, speed: speed,
            picker: MovePicker(router: router, engine: engine, settings: play, persona: persona, dossier: dossier, context: context),
            persona: persona, game: Game(start: start))
    }

    /// Catches the game up with the server's move list, moves when it is the persona's turn, and finishes the game
    /// when the server says it is over. Returns true when the game is over.
    private func advance(_ m: inout Match, _ state: LichessGameState) async throws -> Bool {
        for uci in state.moves.dropFirst(m.game.moves.count) {
            guard let move = Move(uci: uci), m.game.current.isLegal(move) else {
                report(.error("Game \(m.id): server move \(uci) is not legal here"))
                break
            }
            let san = m.game.current.san(for: move)
            let byPersona = m.game.current.sideToMove == m.context.personaColor
            m.game.play(move)
            m.notes.append(MoveNote(ply: m.notes.count, san: san, byPersona: byPersona))
        }
        report(.position(id: m.id, game: m.game, notes: m.notes, whiteMs: state.wtime, blackMs: state.btime))

        if state.isOver {
            await finish(m, state)
            return true
        }
        guard m.game.current.sideToMove == m.context.personaColor, m.game.end == nil else { return false }

        let myMs = m.context.personaColor == .white ? state.wtime : state.btime
        let incMs = m.context.personaColor == .white ? state.winc : state.binc
        let decision = try await m.picker.choose(in: m.game, allowModel: Self.timeAllowsModel(remainingMs: myMs, incrementMs: incMs))
        let san = m.game.current.san(for: decision.move)
        do {
            try await client.move(m.id, uci: decision.move.uci)
        } catch {
            report(.error("Move \(san) was refused: \(error.localizedDescription)"))
            return false
        }
        m.game.play(decision.move)
        m.notes.append(MoveNote(
            ply: m.notes.count, san: san, byPersona: true, source: decision.source, reason: decision.reason,
            evalBefore: decision.evalWhite))
        report(.position(id: m.id, game: m.game, notes: m.notes, whiteMs: state.wtime, blackMs: state.btime))
        return false
    }

    /// A model call takes up to ~10 s: worth it with more than 90 s left, or 30 s with a real increment.
    static func timeAllowsModel(remainingMs: Int, incrementMs: Int) -> Bool {
        remainingMs > 90_000 || (remainingMs > 30_000 && incrementMs >= 5_000)
    }

    private func finish(_ m: Match, _ state: LichessGameState) async {
        let (result, end) = Self.outcome(state)
        guard end != .aborted, !m.game.moves.isEmpty else {
            report(.gameFinished(id: m.id, record: nil, persona: nil))
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let tags: [(String, String)] = [
            ("Event", "Lichess \(m.rated ? "rated" : "casual") \(m.speed)"), ("Site", "https://lichess.org/\(m.id)"),
            ("Date", formatter.string(from: m.started)), ("Round", "-"),
            ("White", m.white.name), ("Black", m.black.name), ("Result", result.rawValue),
        ]
        let usage = await router.totals(since: m.started)
        let calls = await router.records(since: m.started).count
        var record = GameRecord(
            id: "lichess-\(m.id)", date: m.started, personaID: personaID, opponent: m.context.opponent,
            personaColor: m.context.personaColor, result: result, end: end,
            pgn: Self.pgn(m.game, tags: tags, result: result), notes: m.notes, usage: usage, calls: calls)
        // A game this short teaches nothing worth two model calls: it is saved (it counts in the score) unreviewed.
        guard m.game.moves.count >= 6 else {
            try? store.save(record)
            report(.gameFinished(id: m.id, record: record, persona: nil))
            return
        }
        report(.reviewing(id: m.id, result: result))
        do {
            let review = try await GameReviewer(engine: engine).review(m.game, personaColor: m.context.personaColor)
            let outcome = try await MemoryUpdater(router: router, store: store)
                .update(record: record, review: review, persona: store.persona(personaID) ?? m.persona, context: m.context)
            record = outcome.record
            report(.gameFinished(id: m.id, record: record, persona: outcome.persona))
        } catch {
            try? store.save(record)
            report(.error("Review of \(m.id) failed: \(error.localizedDescription). The game was saved."))
            report(.gameFinished(id: m.id, record: record, persona: nil))
        }
    }

    static func outcome(_ state: LichessGameState) -> (GameResult, GameEnd?) {
        let result: GameResult = switch state.winner {
        case "white": .whiteWins
        case "black": .blackWins
        default: ["aborted", "noStart"].contains(state.status) ? .ongoing : .draw
        }
        let end: GameEnd? = switch state.status {
        case "mate": .checkmate
        case "resign": .resignation
        case "stalemate": .stalemate
        case "outoftime", "timeout": .timeout
        case "draw": .drawAgreed
        case "aborted", "noStart": .aborted
        default: nil
        }
        return (result, end)
    }

    /// `Game.pgn` takes its result from the board; a server result (time, resignation, agreed draw) replaces it.
    static func pgn(_ game: Game, tags: [(String, String)], result: GameResult) -> String {
        let text = game.pgn(tags: tags)
        let own = game.result.rawValue
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard own != result.rawValue, body.hasSuffix(own) else { return text }
        return String(body.dropLast(own.count)) + result.rawValue + (body.count < text.count ? "\n" : "")
    }

    private func report(_ update: LichessBotUpdate) { onUpdate(update) }
}
