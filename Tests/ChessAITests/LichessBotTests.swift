import XCTest
import ChessCore
import ChessEngine
@testable import ChessAI

/// Routes by request path; records every request. Never leaves the process.
final class BotStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var body = "" }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) static var log: [(method: String, path: String)] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; log = []
    }
    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return log.map(\.path) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.log.append((request.httpMethod ?? "GET", request.url?.path ?? ""))
        let handler = Self.handler
        Self.lock.unlock()
        let reply = handler?(request) ?? Reply(status: 404, body: "")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LichessBotUpdate] = []
    func add(_ u: LichessBotUpdate) { lock.lock(); items.append(u); lock.unlock() }
    var all: [LichessBotUpdate] { lock.lock(); defer { lock.unlock() }; return items }
    var finished: (record: GameRecord?, persona: PersonaProfile?)? {
        for u in all { if case .gameFinished(_, let r, let p) = u { return (r, p) } }
        return nil
    }
}

final class LichessBotTests: XCTestCase {
    let account = LichessAccount(id: "jsonbot", username: "JsonBot", title: "BOT")

    func stubClient() -> LichessClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BotStubProtocol.self]
        return LichessClient(token: "t", baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: config))
    }

    func makeBot(
        engine: StockfishEngine, settings: LichessBotSettings = LichessBotSettings(), store: MemoryStore? = nil,
        backend: FakeBackend? = nil, onUpdate: @escaping @Sendable (LichessBotUpdate) -> Void = { _ in }
    ) -> LichessBot {
        LichessBot(
            client: stubClient(), account: account, engine: engine,
            router: makeRouter(backend ?? FakeBackend { _ in [:] }), store: store ?? tempStore().0,
            personaID: "json-bourne", settings: settings, play: PlaySettings(), onUpdate: onUpdate)
    }

    func challenge(variant: String = "standard", rated: Bool = false, speed: String = "rapid", bot: Bool = false) -> LichessChallenge {
        LichessChallenge(
            id: "c", challenger: LichessPlayer(id: "x", name: "X", title: bot ? "BOT" : nil, rating: 1500),
            variant: variant, rated: rated, speed: speed, timeControl: "clock", clockLimit: 600, clockIncrement: 0)
    }

    // MARK: declineReason

    func testDeclineReasons() async throws {
        let engine = try await startedEngine()
        let bot = makeBot(engine: engine)
        let r1 = await bot.declineReason(challenge(variant: "chess960"))
        XCTAssertEqual(r1, "standard")
        let r2 = await bot.declineReason(challenge(speed: "bullet"))
        XCTAssertEqual(r2, "tooFast")
        let r3 = await bot.declineReason(challenge(speed: "blitz"))
        XCTAssertEqual(r3, "tooFast")
        let r4 = await bot.declineReason(challenge(rated: true))
        XCTAssertNil(r4)
        let r5 = await bot.declineReason(challenge(rated: false, speed: "classical", bot: true))
        XCTAssertNil(r5)

        var s = LichessBotSettings(); s.speeds.remove("correspondence")
        let b2 = makeBot(engine: engine, settings: s)
        let r6 = await b2.declineReason(challenge(speed: "correspondence"))
        XCTAssertEqual(r6, "timeControl")

        var s3 = LichessBotSettings(); s3.acceptRated = false
        let r7 = await makeBot(engine: engine, settings: s3).declineReason(challenge(rated: true))
        XCTAssertEqual(r7, "casual")
        var s4 = LichessBotSettings(); s4.acceptCasual = false
        let r8 = await makeBot(engine: engine, settings: s4).declineReason(challenge(rated: false))
        XCTAssertEqual(r8, "rated")
        var s5 = LichessBotSettings(); s5.acceptBots = false
        let r9 = await makeBot(engine: engine, settings: s5).declineReason(challenge(bot: true))
        XCTAssertEqual(r9, "noBot")
        let r10 = await makeBot(engine: engine, settings: s5).declineReason(challenge(bot: false))
        XCTAssertNil(r10)
        var s6 = LichessBotSettings(); s6.acceptHumans = false
        let r11 = await makeBot(engine: engine, settings: s6).declineReason(challenge(bot: false))
        XCTAssertEqual(r11, "onlyBot")
        let r12 = await makeBot(engine: engine, settings: s6).declineReason(challenge(bot: true))
        XCTAssertNil(r12)
    }

    // MARK: outcome / time / pgn

    func state(_ status: String, winner: String? = nil) -> LichessGameState {
        LichessGameState(status: status, winner: winner)
    }

    func testOutcome() {
        var (r, e) = LichessBot.outcome(state("mate", winner: "white"))
        XCTAssertEqual(r, .whiteWins); XCTAssertEqual(e, .checkmate)
        (r, e) = LichessBot.outcome(state("resign", winner: "black"))
        XCTAssertEqual(r, .blackWins); XCTAssertEqual(e, .resignation)
        (r, e) = LichessBot.outcome(state("outoftime", winner: "white"))
        XCTAssertEqual(r, .whiteWins); XCTAssertEqual(e, .timeout)
        (r, e) = LichessBot.outcome(state("draw"))
        XCTAssertEqual(r, .draw); XCTAssertEqual(e, .drawAgreed)
        (r, e) = LichessBot.outcome(state("stalemate"))
        XCTAssertEqual(r, .draw); XCTAssertEqual(e, .stalemate)
        (r, e) = LichessBot.outcome(state("aborted"))
        XCTAssertEqual(r, .ongoing); XCTAssertEqual(e, .aborted)
    }

    func testTimeAllowsModel() {
        XCTAssertTrue(LichessBot.timeAllowsModel(remainingMs: 120_000, incrementMs: 0))
        XCTAssertFalse(LichessBot.timeAllowsModel(remainingMs: 60_000, incrementMs: 0))
        XCTAssertTrue(LichessBot.timeAllowsModel(remainingMs: 60_000, incrementMs: 5_000))
        XCTAssertFalse(LichessBot.timeAllowsModel(remainingMs: 20_000, incrementMs: 10_000))
    }

    func testPGNReplacesResult() {
        var game = Game()
        for uci in ["e2e4", "e7e5", "g1f3", "b8c6"] { game.play(Move(uci: uci)!) }
        let tags: [(String, String)] = [("Event", "t"), ("Result", "1-0")]
        let text = LichessBot.pgn(game, tags: tags, result: .whiteWins).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text.hasSuffix("1-0"), text)
        XCTAssertFalse(text.hasSuffix("*"))
        let same = LichessBot.pgn(game, tags: tags, result: .ongoing).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(same.hasSuffix("*"))
    }

    // MARK: Scripted games

    func wait(_ timeout: TimeInterval = 20, until cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
    }

    func gameFull(white: String, black: String, moves: String = "") -> String {
        #"{"type":"gameFull","id":"g1","rated":false,"speed":"rapid","variant":{"key":"standard"},"white":{"id":"\#(white)","name":"\#(white)","rating":1500},"black":{"id":"\#(black)","name":"\#(black)","rating":1500},"initialFen":"startpos","state":{"type":"gameState","moves":"\#(moves)","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started"}}"#
    }

    func gameState(_ moves: String, status: String = "started", winner: String? = nil) -> String {
        let w = winner.map { #","winner":"\#($0)""# } ?? ""
        return #"{"type":"gameState","moves":"\#(moves)","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"\#(status)"\#(w)}"#
    }

    func eventStub(game: [String], secondStream: [String]? = nil) -> @Sendable (URLRequest) -> BotStubProtocol.Reply {
        let served = NSLock()
        nonisolated(unsafe) var eventsServed = false
        nonisolated(unsafe) var streams = 0
        return { req in
            let path = req.url?.path ?? ""
            if path == "/api/stream/event" {
                served.lock(); defer { served.unlock() }
                if eventsServed { return .init(body: "") }
                eventsServed = true
                return .init(body: #"{"type":"gameStart","game":{"gameId":"g1"}}"# + "\n")
            }
            if path == "/api/bot/game/stream/g1" {
                served.lock(); defer { served.unlock() }
                streams += 1
                let lines = (streams > 1 ? secondStream : nil) ?? game
                return .init(body: lines.joined(separator: "\n") + "\n")
            }
            return .init(body: #"{"ok":true}"#)
        }
    }

    func testScriptedGameFromBook() async throws {
        let engine = try await startedEngine()
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }

        var persona = MemoryStore.defaultPersona
        persona.notes = [note("rep", .opening, confidence: 0.9, line: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"], side: .white)]
        try store.save(persona)
        let human = OpponentDossier(opponent: .human("alice"))
        var humanDossier = human
        humanDossier.notes = [note("h", .tendency)]
        try store.save(humanDossier, persona: persona.id, in: singlePlayer(.human("alice")))
        let humanFile = root.appendingPathComponent("personas/\(persona.id)/opponents/human-alice.json")
        let before = try Data(contentsOf: humanFile)

        let backend = FakeBackend { req in
            if req.system.contains("self-knowledge") { return ["summary": "A short win.", "notes": [[String: Any]]()] }
            if req.system.contains("scouting file") { return ["notes": [[String: Any]]()] }
            throw FakeFailure()
        }
        BotStubProtocol.reset(eventStub(game: [
            gameFull(white: "jsonbot", black: "alice"),
            gameState("e2e4 e7e5"),
            gameState("e2e4 e7e5 g1f3 b8c6"),
            gameState("e2e4 e7e5 g1f3 b8c6 f1b5 a7a6", status: "resign", winner: "white"),
        ]))
        let box = UpdateBox()
        let bot = makeBot(engine: engine, store: store, backend: backend) { box.add($0) }
        await bot.start()
        await wait { box.finished != nil }
        await bot.stop()

        let moves = BotStubProtocol.paths.filter { $0.contains("/move/") }
        XCTAssertEqual(moves, ["/api/bot/game/g1/move/e2e4", "/api/bot/game/g1/move/g1f3", "/api/bot/game/g1/move/f1b5"])

        let started = box.all.compactMap { u -> (LichessPlayer, PieceColor)? in
            if case .gameStarted(_, let o, let c, _, _) = u { return (o, c) } else { return nil }
        }
        XCTAssertEqual(started.first?.0.name, "alice")
        XCTAssertEqual(started.first?.1, .white)

        let fin = try XCTUnwrap(box.finished)
        let record = try XCTUnwrap(fin.record, "errors: \(box.all)")
        XCTAssertEqual(record.result, .whiteWins)
        XCTAssertEqual(record.end, .resignation)
        XCTAssertEqual(record.opponent, .lichess("alice"))
        XCTAssertEqual(record.notes.count, 6)
        XCTAssertEqual(record.notes.map(\.byPersona), [true, false, true, false, true, false])
        for n in record.notes where n.byPersona { XCTAssertEqual(n.source, .book) }
        XCTAssertTrue(record.pgn.contains(#"[Site "https://lichess.org/g1"]"#), record.pgn)
        XCTAssertTrue(record.pgn.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("1-0"), record.pgn)

        let dossierFile = root.appendingPathComponent("personas/\(persona.id)/opponents/lichess-alice.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dossierFile.path))
        XCTAssertEqual(try Data(contentsOf: humanFile), before)
        XCTAssertEqual(store.games().count, 1)
    }

    func testAbortedGameSavesNothing() async throws {
        let engine = try await startedEngine()
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        BotStubProtocol.reset(eventStub(game: [
            gameFull(white: "alice", black: "jsonbot"),
            gameState("", status: "aborted"),
        ]))
        let box = UpdateBox()
        let bot = makeBot(engine: engine, store: store) { box.add($0) }
        await bot.start()
        await wait { box.finished != nil }
        await bot.stop()

        let fin = try XCTUnwrap(box.finished)
        XCTAssertNil(fin.record)
        XCTAssertTrue(store.games().isEmpty)
        XCTAssertTrue(BotStubProtocol.paths.filter { $0.contains("/move/") }.isEmpty)
    }

    func testDroppedStreamIsReopenedWithoutRepostingMoves() async throws {
        let engine = try await startedEngine()
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var persona = MemoryStore.defaultPersona
        persona.notes = [note("rep", .opening, confidence: 0.9, line: ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"], side: .white)]
        try store.save(persona)
        let backend = FakeBackend { req in
            if req.system.contains("self-knowledge") { return ["summary": "s", "notes": [[String: Any]]()] }
            if req.system.contains("scouting file") { return ["notes": [[String: Any]]()] }
            throw FakeFailure()
        }
        BotStubProtocol.reset(eventStub(
            game: [gameFull(white: "jsonbot", black: "alice"), gameState("e2e4 e7e5")],
            secondStream: [
                gameFull(white: "jsonbot", black: "alice", moves: "e2e4 e7e5 g1f3 b8c6"),
                gameState("e2e4 e7e5 g1f3 b8c6 f1b5 a7a6", status: "resign", winner: "white"),
            ]))
        let box = UpdateBox()
        let bot = makeBot(engine: engine, store: store, backend: backend) { box.add($0) }
        await bot.start()
        await wait { box.finished != nil }
        await bot.stop()

        let moves = BotStubProtocol.paths.filter { $0.contains("/move/") }
        XCTAssertEqual(moves, ["/api/bot/game/g1/move/e2e4", "/api/bot/game/g1/move/g1f3", "/api/bot/game/g1/move/f1b5"])
        let started = box.all.filter { if case .gameStarted = $0 { true } else { false } }
        XCTAssertEqual(started.count, 1)
        let record = try XCTUnwrap(box.finished?.record, "errors: \(box.all)")
        XCTAssertEqual(record.result, .whiteWins)
        XCTAssertEqual(record.notes.count, 6)
    }

    // MARK: One game at a time

    /// Regression: a second challenge arriving before the first one's game had started was accepted too, so two games
    /// ran at once and the first one's summary replaced the second one's on screen.
    func testGreetingNamesTheEngine() {
        XCTAssertEqual(
            LichessBot.greeting(engine: "ChessSearch"),
            "Hi! I'm JSON Bourne, an LLM persona choosing among ChessSearch's candidate moves. Good luck!")
    }

    func testSettingsSavedWithAGreetingStillLoad() throws {
        let saved = #"{"speeds":["rapid"],"acceptRated":true,"acceptCasual":false,"acceptBots":true,"acceptHumans":true,"greeting":"old"}"#
        let settings = try JSONDecoder().decode(LichessBotSettings.self, from: Data(saved.utf8))
        XCTAssertEqual(settings.speeds, ["rapid"])
        XCTAssertFalse(settings.acceptCasual)
    }

    func testSecondChallengeBeforeGameStartIsDeclined() async throws {
        let engine = try await startedEngine()
        defer { Task { await engine.shutdown() } }
        func line(_ id: String) -> String {
            #"{"type":"challenge","challenge":{"id":"\#(id)","challenger":{"id":"x","name":"X","rating":1500},"variant":{"key":"standard"},"rated":false,"speed":"rapid","timeControl":{"type":"clock","limit":600,"increment":5},"color":"random"}}"#
        }
        let body = line("c1") + "\n" + line("c2") + "\n"
        BotStubProtocol.reset { request in
            request.url?.path == "/api/stream/event" ? .init(body: body) : .init(body: #"{"ok":true}"#)
        }
        let bot = makeBot(engine: engine)
        await bot.start()
        for _ in 0..<100 where !BotStubProtocol.paths.contains("/api/challenge/c2/decline") {
            try await Task.sleep(for: .milliseconds(50))
        }
        await bot.stop()
        XCTAssertTrue(BotStubProtocol.paths.contains("/api/challenge/c1/accept"), "\(BotStubProtocol.paths)")
        XCTAssertTrue(BotStubProtocol.paths.contains("/api/challenge/c2/decline"), "\(BotStubProtocol.paths)")
        XCTAssertFalse(BotStubProtocol.paths.contains("/api/challenge/c2/accept"))
    }

    func testServerDrawKeepsTheRuleTheBoardShows() {
        // Lichess said only "draw"; this repetition is the game's real ending (8L5R3JaG).
        var game = Game(start: Position(fen: "8/2k5/p1P4p/1pK5/6P1/8/8/8 w - - 0 53")!)
        for uci in ["c5d5", "c7c8", "d5c5", "c8c7", "c5d5", "c7b8", "d5d6", "b8c8", "d6c5", "c8c7"] {
            XCTAssertTrue(game.play(Move(uci: uci)!), uci)
        }
        XCTAssertEqual(game.end, .threefoldRepetition)
        XCTAssertEqual(LichessBot.end(server: .drawAgreed, board: game.end), .threefoldRepetition)
        XCTAssertEqual(LichessBot.end(server: .drawAgreed, board: nil), .drawAgreed)
        XCTAssertEqual(LichessBot.end(server: .timeout, board: .threefoldRepetition), .timeout)
    }
}
