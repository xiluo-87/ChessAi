import XCTest
@testable import ChessAI

final class LichessStubProtocol: URLProtocol, @unchecked Sendable {
    struct Captured { var url: URL?; var method: String?; var headers: [String: String]; var body: String }
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var captured: Captured?
    private static let lock = NSLock()

    static func configure(status: Int = 200, body: String = "") {
        lock.lock(); defer { lock.unlock() }
        self.status = status; responseBody = Data(body.utf8); captured = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        } else if let b = request.httpBody { body = b }
        Self.lock.lock()
        Self.captured = Captured(url: request.url, method: request.httpMethod,
                                 headers: request.allHTTPHeaderFields ?? [:], body: String(decoding: body, as: UTF8.self))
        let status = Self.status, data = Self.responseBody
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class LichessClientTests: XCTestCase {
    func makeClient() -> LichessClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LichessStubProtocol.self]
        return LichessClient(token: "tok123", baseURL: URL(string: "https://example.test")!,
                             session: URLSession(configuration: config))
    }

    // MARK: Parsing

    func testBlankLineIsNil() throws {
        XCTAssertNil(try LichessClient.parseEvent(""))
        XCTAssertNil(try LichessClient.parseEvent("  \n"))
        XCTAssertNil(try LichessClient.parseGameEvent(""))
    }

    func testClockChallenge() throws {
        let line = #"{"type":"challenge","challenge":{"id":"ch1","challenger":{"id":"bob","name":"Bob","title":"BOT","rating":1800},"destUser":{"id":"me","name":"Me"},"variant":{"key":"standard"},"rated":true,"speed":"blitz","timeControl":{"type":"clock","limit":300,"increment":3},"color":"random","direction":"in"}}"#
        guard case .challenge(let c)? = try LichessClient.parseEvent(line) else { return XCTFail() }
        XCTAssertEqual(c.id, "ch1")
        XCTAssertEqual(c.challenger, LichessPlayer(id: "bob", name: "Bob", title: "BOT", rating: 1800))
        XCTAssertTrue(c.challenger!.isBot)
        XCTAssertEqual(c.variant, "standard")
        XCTAssertTrue(c.rated)
        XCTAssertEqual(c.speed, "blitz")
        XCTAssertEqual(c.timeControl, "clock")
        XCTAssertEqual(c.clockLimit, 300)
        XCTAssertEqual(c.clockIncrement, 3)
        XCTAssertNil(c.daysPerTurn)
        XCTAssertEqual(c.direction, "in")
    }

    func testCorrespondenceAndNullChallenger() throws {
        let line = #"{"type":"challenge","challenge":{"id":"ch2","challenger":null,"variant":{"key":"chess960"},"rated":false,"speed":"correspondence","timeControl":{"type":"correspondence","daysPerTurn":3},"color":"white"}}"#
        guard case .challenge(let c)? = try LichessClient.parseEvent(line) else { return XCTFail() }
        XCTAssertNil(c.challenger)
        XCTAssertEqual(c.timeControl, "correspondence")
        XCTAssertEqual(c.daysPerTurn, 3)
        XCTAssertNil(c.clockLimit)
        XCTAssertEqual(c.variant, "chess960")
        XCTAssertNil(c.direction)
    }

    func testCancelDeclineAndGameEvents() throws {
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"challengeCanceled","challenge":{"id":"x1"}}"#), .challengeCanceled("x1"))
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"challengeDeclined","challenge":{"id":"x2"}}"#), .challengeDeclined("x2"))
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"gameStart","game":{"gameId":"abc12345","fullId":"abc12345xyz1","color":"white"}}"#), .gameStart("abc12345"))
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"gameStart","game":{"id":"legacy01"}}"#), .gameStart("legacy01"))
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"gameFinish","game":{"gameId":"abc12345"}}"#), .gameFinish("abc12345"))
    }

    func testUnknownTypeIsOther() throws {
        XCTAssertEqual(try LichessClient.parseEvent(#"{"type":"mystery"}"#), .other("mystery"))
        XCTAssertEqual(try LichessClient.parseGameEvent(#"{"type":"mystery"}"#), .other("mystery"))
    }

    func testGarbageThrowsDecoding() {
        XCTAssertThrowsError(try LichessClient.parseEvent("not json"))
    }

    func testGameFullWithAIPlayer() throws {
        let line = #"{"type":"gameFull","id":"g1","rated":false,"speed":"rapid","variant":{"key":"standard"},"white":{"aiLevel":3},"black":{"id":"me","name":"Me","title":"BOT","rating":2000},"initialFen":"startpos","state":{"type":"gameState","moves":"","wtime":600000,"btime":600000,"winc":5000,"binc":5000,"status":"started"}}"#
        guard case .full(let id, let white, let black, let fen, let rated, let speed, let variant, let state)? = try LichessClient.parseGameEvent(line) else { return XCTFail() }
        XCTAssertEqual(id, "g1")
        XCTAssertEqual(white.id, "lichess-ai-3")
        XCTAssertEqual(white.name, "Lichess AI level 3")
        XCTAssertEqual(black.name, "Me")
        XCTAssertTrue(black.isBot)
        XCTAssertEqual(fen, "startpos")
        XCTAssertFalse(rated)
        XCTAssertEqual(speed, "rapid")
        XCTAssertEqual(variant, "standard")
        XCTAssertEqual(state.moves, [])
        XCTAssertEqual(state.wtime, 600000)
        XCTAssertEqual(state.binc, 5000)
        XCTAssertFalse(state.isOver)
    }

    func testGameStateOverAndDraw() throws {
        guard case .state(let s)? = try LichessClient.parseGameEvent(#"{"type":"gameState","moves":"e2e4 e7e5 d1h5","wtime":1000,"btime":2000,"winc":0,"binc":0,"status":"started","bdraw":true}"#) else { return XCTFail() }
        XCTAssertEqual(s.moves, ["e2e4", "e7e5", "d1h5"])
        XCTAssertTrue(s.drawOffered)
        XCTAssertFalse(s.isOver)
        XCTAssertNil(s.winner)

        guard case .state(let o)? = try LichessClient.parseGameEvent(#"{"type":"gameState","moves":"f2f3","wtime":1,"btime":1,"winc":0,"binc":0,"status":"mate","winner":"white"}"#) else { return XCTFail() }
        XCTAssertTrue(o.isOver)
        XCTAssertEqual(o.winner, "white")
        XCTAssertFalse(o.drawOffered)
    }

    func testChatAndOpponentGone() throws {
        XCTAssertEqual(try LichessClient.parseGameEvent(#"{"type":"chatLine","username":"bob","text":"hi","room":"spectator"}"#),
                       .chat(username: "bob", text: "hi", room: "spectator"))
        XCTAssertEqual(try LichessClient.parseGameEvent(#"{"type":"opponentGone","gone":true,"claimWinInSeconds":10}"#), .opponentGone(true))
    }

    // MARK: Requests

    func testMoveRequest() async throws {
        LichessStubProtocol.configure(body: #"{"ok":true}"#)
        try await makeClient().move("abc12345", uci: "e2e4")
        let c = try XCTUnwrap(LichessStubProtocol.captured)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url?.absoluteString, "https://example.test/api/bot/game/abc12345/move/e2e4")
        XCTAssertEqual(c.headers["Authorization"], "Bearer tok123")

        try await makeClient().move("abc12345", uci: "e7e8q", offeringDraw: true)
        XCTAssertEqual(LichessStubProtocol.captured?.url?.absoluteString,
                       "https://example.test/api/bot/game/abc12345/move/e7e8q?offeringDraw=true")
    }

    func testDeclineForm() async throws {
        LichessStubProtocol.configure(body: #"{"ok":true}"#)
        try await makeClient().decline("ch1", reason: "tooFast")
        let c = try XCTUnwrap(LichessStubProtocol.captured)
        XCTAssertEqual(c.method, "POST")
        XCTAssertEqual(c.url?.path, "/api/challenge/ch1/decline")
        XCTAssertEqual(c.body, "reason=tooFast")
        XCTAssertEqual(c.headers["Content-Type"], "application/x-www-form-urlencoded")
    }

    func testChallengeUserBothShapes() async throws {
        LichessStubProtocol.configure(body: #"{"id":"newch"}"#)
        let id = try await makeClient().challenge(username: "someone", rated: false, clockLimit: 180, increment: 2, color: "white")
        XCTAssertEqual(id, "newch")
        let c = try XCTUnwrap(LichessStubProtocol.captured)
        XCTAssertEqual(c.url?.path, "/api/challenge/someone")
        let fields = Set(c.body.split(separator: "&").map(String.init))
        XCTAssertEqual(fields, ["rated=false", "clock.limit=180", "clock.increment=2", "color=white", "variant=standard"])

        LichessStubProtocol.configure(body: #"{"challenge":{"id":"nested"}}"#)
        let id2 = try await makeClient().challenge(username: "someone", rated: true, clockLimit: 60, increment: 0)
        XCTAssertEqual(id2, "nested")
        XCTAssertTrue(LichessStubProtocol.captured!.body.contains("rated=true"))
    }

    func testChallengeAI() async throws {
        LichessStubProtocol.configure(body: #"{"id":"aigame1","variant":{"key":"standard"}}"#)
        let id = try await makeClient().challengeAI(level: 4, clockLimit: 300, increment: 0)
        XCTAssertEqual(id, "aigame1")
        XCTAssertEqual(LichessStubProtocol.captured?.url?.path, "/api/challenge/ai")
        XCTAssertTrue(LichessStubProtocol.captured!.body.contains("level=4"))
    }

    func testAccount() async throws {
        LichessStubProtocol.configure(body: #"{"id":"mybot","username":"MyBot","title":"BOT"}"#)
        let a = try await makeClient().account()
        XCTAssertEqual(a, LichessAccount(id: "mybot", username: "MyBot", title: "BOT"))
        XCTAssertTrue(a.isBot)
        XCTAssertEqual(LichessStubProtocol.captured?.method, "GET")
    }

    func testChatBody() async throws {
        LichessStubProtocol.configure(body: #"{"ok":true}"#)
        try await makeClient().chat("g1", text: "good luck & have fun")
        XCTAssertEqual(LichessStubProtocol.captured?.body, "room=player&text=good%20luck%20%26%20have%20fun")
    }

    func testErrors() async {
        LichessStubProtocol.configure(status: 401, body: #"{"error":"No such token"}"#)
        do { _ = try await makeClient().account(); XCTFail() } catch LichessError.unauthorized {} catch { XCTFail("\(error)") }

        LichessStubProtocol.configure(status: 429, body: "")
        do { try await makeClient().resign("g1"); XCTFail() } catch LichessError.rateLimited {} catch { XCTFail("\(error)") }

        LichessStubProtocol.configure(status: 400, body: #"{"error":"Not your turn"}"#)
        do { try await makeClient().move("g1", uci: "e2e4"); XCTFail() } catch LichessError.http(let code, let msg) {
            XCTAssertEqual(code, 400); XCTAssertEqual(msg, "Not your turn")
        } catch { XCTFail("\(error)") }
    }

    // MARK: Streams

    func testEventsStream() async throws {
        let body = [
            "",
            #"{"type":"challenge","challenge":{"id":"c1","challenger":{"id":"bob","name":"Bob"},"variant":{"key":"standard"},"rated":false,"speed":"blitz","timeControl":{"type":"clock","limit":180,"increment":0},"color":"random"}}"#,
            "",
            #"{"type":"gameStart","game":{"gameId":"g1"}}"#,
            "",
            #"{"type":"gameFinish","game":{"gameId":"g1"}}"#,
        ].joined(separator: "\n") + "\n"
        LichessStubProtocol.configure(body: body)
        var events: [LichessEvent] = []
        for try await e in makeClient().events() { events.append(e) }
        XCTAssertEqual(events.count, 3)
        guard case .challenge(let c) = events[0] else { return XCTFail() }
        XCTAssertEqual(c.id, "c1")
        XCTAssertEqual(events[1], .gameStart("g1"))
        XCTAssertEqual(events[2], .gameFinish("g1"))
        XCTAssertEqual(LichessStubProtocol.captured?.url?.path, "/api/stream/event")
    }

    func testGameStream() async throws {
        let body = #"{"type":"gameFull","id":"g1","white":{"id":"a","name":"A"},"black":{"aiLevel":1},"state":{"moves":"e2e4","wtime":1,"btime":1,"winc":0,"binc":0,"status":"started"}}"# + "\n\n"
            + #"{"type":"gameState","moves":"e2e4 e7e5","wtime":1,"btime":1,"winc":0,"binc":0,"status":"started"}"# + "\n"
        LichessStubProtocol.configure(body: body)
        var events: [LichessGameEvent] = []
        for try await e in makeClient().gameEvents("g1") { events.append(e) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(LichessStubProtocol.captured?.url?.path, "/api/bot/game/stream/g1")
    }

    func testStreamHTTPErrorThrows() async {
        LichessStubProtocol.configure(status: 401, body: #"{"error":"bad"}"#)
        do {
            for try await _ in makeClient().events() {}
            XCTFail()
        } catch LichessError.unauthorized {} catch { XCTFail("\(error)") }
    }

    func testParseOnlineBot() throws {
        let line = #"{"id":"maia1","username":"maia1","title":"BOT","perfs":{"blitz":{"games":1200,"rating":1540,"rd":45,"prog":3},"rapid":{"games":300,"rating":1600,"rd":60,"prog":0}},"seenAt":1}"#
        let bot = try XCTUnwrap(LichessClient.parseBot(line))
        XCTAssertEqual(bot.username, "maia1")
        XCTAssertEqual(bot.ratings["blitz"], 1540)
        XCTAssertEqual(bot.games["rapid"], 300)
        XCTAssertFalse(bot.tosViolation)
        XCTAssertNil(try LichessClient.parseBot("   "))
    }
}
