import Foundation
import Security
import SwiftUI
import ChessCore
import ChessAI

/// The Lichess API token in the login Keychain; never in UserDefaults or files.
enum TokenStore {
    private static let service = "ChessAi.lichess"
    private static let account = "api-token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The app's side of the Lichess bot: account, bot on/off, challenges, and the live game mirrored onto the board.
@MainActor
final class LichessController: ObservableObject {
    struct LogLine: Identifiable { let id = UUID(); let date = Date(); let text: String; let isError: Bool }

    @Published private(set) var hasToken = TokenStore.load() != nil
    @Published private(set) var account: LichessAccount?
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var currentGame: String?
    @Published private(set) var opponent: LichessPlayer?
    @Published private(set) var personaColor: PieceColor = .white
    /// The speed of the current game, to show the persona's rating for it.
    @Published private(set) var currentSpeed: String?
    /// Nil until the persona has played rated games at this speed (casual games never change a rating).
    var personaRating: Int? { currentSpeed.flatMap { account?.ratings[$0] } }
    @Published private(set) var clocks: (white: Int, black: Int) = (0, 0)
    /// When `clocks` arrived: the side to move's clock runs down from here.
    @Published private(set) var clockStamp = Date()
    @Published var settings = LichessController.loadSettings() { didSet { saveSettings() } }
    /// Bots online now, the bot's lobby (bots cannot post seeks in the human lobby).
    @Published private(set) var bots: [LichessBotInfo] = []
    /// Bots that cannot or will not play us now (daily bot-game limit, declined), by lowercased name, until when.
    @Published private(set) var unavailable: [String: Date] = LichessController.loadUnavailable()
    /// Our outgoing challenges, id → opponent, to name the bot when a decline arrives.
    private var outgoing: [String: String] = [:]

    private weak var app: AppModel?
    private var bot: LichessBot?
    private var updates: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var client: LichessClient? { TokenStore.load().map { LichessClient(token: $0) } }

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        TokenStore.save(trimmed)
        hasToken = true
        Task { await connect() }
    }

    func forgetToken() {
        stop()
        TokenStore.delete()
        hasToken = false
        account = nil
    }

    func connect(quietly: Bool = false) async {
        guard let client else { return }
        await perform("Connecting") { self.account = try await client.account() }
        if let account, !quietly { note("Signed in as \(account.username)\(account.isBot ? " (BOT)" : " — not a BOT account yet").") }
    }

    func upgrade() async {
        guard let client else { return }
        await perform("Upgrading to BOT") { try await client.upgradeToBot() }
        await connect()
    }

    func start() {
        guard let app, let client, let account, account.isBot, let engine = app.engineInstance else { return }
        let (stream, continuation) = AsyncStream<LichessBotUpdate>.makeStream()
        let bot = LichessBot(
            client: client, account: account, engine: engine, router: app.router, store: app.store,
            personaID: app.persona.id, settings: settings, play: app.settings.play,
            onUpdate: { continuation.yield($0) })
        self.bot = bot
        updates = Task { [weak self] in
            for await update in stream { self?.apply(update) }
        }
        Task { await bot.start() }
        running = true
    }

    func stop() {
        guard let bot else { return }
        Task { await bot.stop() }
        running = false
    }

    func resign() {
        guard let bot, let id = currentGame else { return }
        Task { await bot.resign(id) }
    }

    func challenge(username: String, minutes: Int, increment: Int, rated: Bool) async {
        guard let client, running else { note("Start the bot first, so it can play the game when it begins.", error: true); return }
        await perform("Challenging \(username)") {
            do {
                let id = try await client.challenge(username: username, rated: rated, clockLimit: minutes * 60, increment: increment)
                self.outgoing[id] = username
                self.note("Challenge sent to \(username).")
            } catch LichessError.http(400, let message) where message.contains("games against other bots today") {
                // Lichess caps games between bots per day; the message says until when.
                let until = Self.waitUntil(in: message) ?? Date().addingTimeInterval(12 * 3600)
                self.markUnavailable(username, until: until)
                self.note("\(username) has played its 100 bot games for today; hidden from the lobby until \(until.formatted(date: .omitted, time: .shortened)).")
            }
        }
    }

    func isAvailable(_ username: String) -> Bool {
        (unavailable[username.lowercased()] ?? .distantPast) < Date()
    }

    private func markUnavailable(_ username: String, until: Date) {
        unavailable[username.lowercased()] = until
        unavailable = unavailable.filter { $0.value > Date() }
        if let data = try? JSONEncoder().encode(unavailable) { UserDefaults.standard.set(data, forKey: Self.unavailableKey) }
    }

    static func waitUntil(in message: String) -> Date? {
        guard let range = message.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"#, options: .regularExpression) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let text = String(message[range])
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static let unavailableKey = "lichess.unavailable.v1"

    private static func loadUnavailable() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: unavailableKey),
              let value = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return value.filter { $0.value > Date() }
    }

    func challengeAI(level: Int, minutes: Int, increment: Int) async {
        guard let client, running else { note("Start the bot first, so it can play the game when it begins.", error: true); return }
        await perform("Challenging Lichess AI level \(level)") {
            let id = try await client.challengeAI(level: level, clockLimit: minutes * 60, increment: increment)
            self.note("Game \(id) against Lichess AI level \(level) created.")
        }
    }

    func refreshBots() async {
        guard let client else { return }
        await perform("Loading online bots") {
            let own = self.account?.id.lowercased()
            self.bots = try await client.onlineBots(limit: 150).filter { !$0.tosViolation && $0.id.lowercased() != own }
        }
    }

    /// Lichess's speed for a clock: estimated duration = initial + 40 × increment.
    static func speed(minutes: Int, increment: Int) -> String {
        switch minutes * 60 + 40 * increment {
        case ..<30: "ultraBullet"
        case ..<180: "bullet"
        case ..<480: "blitz"
        case ..<1500: "rapid"
        default: "classical"
        }
    }

    // MARK: Updates

    private func apply(_ update: LichessBotUpdate) {
        switch update {
        case .status(let text):
            note(text)
        case .error(let text):
            note(text, error: true)
        case .challenge(let c, let accepted, let reason):
            let who = c.challenger.map { "\($0.name)\($0.rating.map { " (\($0))" } ?? "")" } ?? "open challenge"
            note("\(accepted ? "Accepted" : "Declined") \(c.speed) \(c.rated ? "rated" : "casual") challenge from \(who)\(reason.map { ": \($0)" } ?? "").")
        case .gameStarted(let id, let opponent, let color, let rated, let speed):
            currentGame = id
            self.opponent = opponent
            personaColor = color
            currentSpeed = speed
            note("Game \(id) started: \(app?.persona.name ?? "Persona") plays \(color.rawValue) vs \(opponent.name), \(rated ? "rated" : "casual") \(speed).")
        case .position(let id, let game, let notes, let whiteMs, let blackMs):
            guard id == currentGame, let app else { return }
            clocks = (whiteMs, blackMs)
            clockStamp = Date()
            let color = personaColor
            app.showExternal(game: game, notes: notes, personaColor: color,
                             status: "Lichess vs \(opponent?.name ?? "?") — \(game.current.sideToMove == color ? "\(app.persona.name) is thinking…" : "waiting for the opponent")")
        case .outgoingDeclined(let id):
            let name = outgoing.removeValue(forKey: id) ?? "A bot"
            note("\(name) declined the challenge; hidden from the lobby for an hour.")
            markUnavailable(name, until: Date().addingTimeInterval(3600))
        case .reviewing(let id, let result):
            note("Game \(id) over (\(result.rawValue)); reviewing it into memory…")
            if id == currentGame { app?.externalReviewing(result: result) }
        case .gameFinished(let id, let record, let persona):
            if let persona { app?.personaUpdated(persona) }
            app?.refreshScores()
            Task { await self.connect(quietly: true) }  // the account's ratings changed
            if let record, record.review != nil { app?.showRecord(record) }
            note("Game \(id) finished" + (record.map { ": \($0.result.rawValue)" + ($0.review == nil ? " (too short to review; counted in the score)" : "") } ?? " (aborted)") + ".")
            if id == currentGame {
                currentGame = nil
                app?.endExternal(record: record)
            }
        }
    }

    private func note(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func perform(_ what: String, _ body: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
        } catch {
            note("\(what) failed: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Settings

    private static let key = "lichess.settings.v1"

    private static func loadSettings() -> LichessBotSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(LichessBotSettings.self, from: data) else { return LichessBotSettings() }
        return value
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
        if running { note("Settings apply after the bot restarts.") }
    }
}
