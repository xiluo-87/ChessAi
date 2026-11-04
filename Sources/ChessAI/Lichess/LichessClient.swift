import Foundation

/// Minimal Lichess Bot API client (Foundation only).
public final class LichessClient: Sendable {
    private let token: String
    private let baseURL: URL
    private let session: URLSession

    public init(token: String, baseURL: URL = URL(string: "https://lichess.org")!, session: URLSession = .shared) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Requests

    private func makeRequest(_ path: String, method: String = "GET", query: [(String, String)] = [],
                             form: [(String, String)]? = nil) -> URLRequest {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.percentEncodedPath = basePath + path
        if !query.isEmpty {
            comps.percentEncodedQueryItems = query.map {
                URLQueryItem(name: Self.encode($0.0), value: Self.encode($0.1))
            }
        }
        var request = URLRequest(url: comps.url ?? baseURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(form.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&").utf8)
        } else if method == "POST" {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data()
        }
        return request
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    private static func pathSegment(_ s: String) -> String { encode(s) }

    private static func check(status: Int, body: Data) throws {
        guard !(200..<300).contains(status) else { return }
        switch status {
        case 401: throw LichessError.unauthorized
        case 429: throw LichessError.rateLimited
        default:
            var message = String(decoding: body.prefix(2000), as: UTF8.self)
            if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                if let e = obj["error"] as? String { message = e }
                else if let e = obj["error"] as? [String: Any] { message = String(describing: e) }
            }
            throw LichessError.http(status, message)
        }
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LichessError.http(0, "No HTTP response") }
        try Self.check(status: http.statusCode, body: data)
        return data
    }

    private func sendJSON(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await send(request)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LichessError.decoding("Expected a JSON object")
        }
        return obj
    }

    private func stream<T: Sendable>(_ request: URLRequest, parse: @escaping @Sendable (String) throws -> T?)
        -> AsyncThrowingStream<T, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [session] in
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw LichessError.http(0, "No HTTP response") }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await b in bytes {
                            body.append(b)
                            if body.count > 4000 { break }
                        }
                        try Self.check(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        if let item = try parse(line) { continuation.yield(item) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Account

    public func account() async throws -> LichessAccount {
        let obj = try await sendJSON(makeRequest("/api/account"))
        guard let username = obj.str("username") else { throw LichessError.decoding("account: missing username") }
        // Only ratings earned in games: a speed never played shows Lichess's placeholder (a provisional 1500 or,
        // for bots, 3000) with 0 games.
        var ratings: [String: Int] = [:]
        for (perf, value) in obj.dict("perfs") ?? [:] {
            guard let p = value as? [String: Any], let rating = p.int("rating"), (p.int("games") ?? 0) > 0 else { continue }
            ratings[perf] = rating
        }
        return LichessAccount(id: obj.str("id") ?? username.lowercased(), username: username, title: obj.str("title"), ratings: ratings)
    }

    public func upgradeToBot() async throws {
        try await send(makeRequest("/api/bot/account/upgrade", method: "POST"))
    }

    // MARK: - Streams

    public func events() -> AsyncThrowingStream<LichessEvent, Error> {
        stream(makeRequest("/api/stream/event")) { try Self.parseEvent($0) }
    }

    public func gameEvents(_ gameID: String) -> AsyncThrowingStream<LichessGameEvent, Error> {
        stream(makeRequest("/api/bot/game/stream/\(Self.pathSegment(gameID))")) { try Self.parseGameEvent($0) }
    }

    // MARK: - Actions

    public func accept(_ challengeID: String) async throws {
        try await send(makeRequest("/api/challenge/\(Self.pathSegment(challengeID))/accept", method: "POST"))
    }

    public func decline(_ challengeID: String, reason: String) async throws {
        try await send(makeRequest("/api/challenge/\(Self.pathSegment(challengeID))/decline", method: "POST",
                                   form: [("reason", reason)]))
    }

    /// Withdraws a challenge we sent that has not been answered.
    public func cancelChallenge(_ challengeID: String) async throws {
        try await send(makeRequest("/api/challenge/\(Self.pathSegment(challengeID))/cancel", method: "POST"))
    }

    public func move(_ gameID: String, uci: String, offeringDraw: Bool = false) async throws {
        try await send(makeRequest("/api/bot/game/\(Self.pathSegment(gameID))/move/\(Self.pathSegment(uci))",
                                   method: "POST", query: offeringDraw ? [("offeringDraw", "true")] : []))
    }

    public func resign(_ gameID: String) async throws {
        try await send(makeRequest("/api/bot/game/\(Self.pathSegment(gameID))/resign", method: "POST"))
    }

    public func abort(_ gameID: String) async throws {
        try await send(makeRequest("/api/bot/game/\(Self.pathSegment(gameID))/abort", method: "POST"))
    }

    public func chat(_ gameID: String, text: String, room: String = "player") async throws {
        try await send(makeRequest("/api/bot/game/\(Self.pathSegment(gameID))/chat", method: "POST",
                                   form: [("room", room), ("text", text)]))
    }

    public func challenge(username: String, rated: Bool, clockLimit: Int, increment: Int,
                          color: String = "random") async throws -> String {
        let obj = try await sendJSON(makeRequest("/api/challenge/\(Self.pathSegment(username))", method: "POST", form: [
            ("rated", rated ? "true" : "false"),
            ("clock.limit", String(clockLimit)),
            ("clock.increment", String(increment)),
            ("color", color),
            ("variant", "standard"),
        ]))
        if let id = obj.str("id") { return id }
        if let id = obj.dict("challenge")?.str("id") { return id }
        throw LichessError.decoding("challenge response has no id")
    }

    public func challengeAI(level: Int, clockLimit: Int, increment: Int, color: String = "random") async throws -> String {
        let obj = try await sendJSON(makeRequest("/api/challenge/ai", method: "POST", form: [
            ("level", String(level)),
            ("clock.limit", String(clockLimit)),
            ("clock.increment", String(increment)),
            ("color", color),
            ("variant", "standard"),
        ]))
        if let id = obj.str("id") { return id }
        if let id = obj.dict("game")?.str("id") { return id }
        throw LichessError.decoding("challengeAI response has no id")
    }

    /// The bots online now (GET /api/bot/online, NDJSON): the closest thing to a lobby, since bots cannot post seeks.
    public func onlineBots(limit: Int = 100) async throws -> [LichessBotInfo] {
        var request = makeRequest("/api/bot/online", query: [("nb", String(limit))])
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let body = String(decoding: try await send(request), as: UTF8.self)
        return try body.split(separator: "\n").compactMap { try Self.parseBot(String($0)) }
    }

    static func parseBot(_ line: String) throws -> LichessBotInfo? {
        guard let obj = try object(line), let id = obj.str("id") else { return nil }
        var ratings: [String: Int] = [:], games: [String: Int] = [:]
        for (perf, value) in obj.dict("perfs") ?? [:] {
            guard let p = value as? [String: Any], let rating = p.int("rating"), (p.int("games") ?? 0) > 0 else { continue }
            ratings[perf] = rating
            games[perf] = p.int("games") ?? 0
        }
        return LichessBotInfo(id: id, username: obj.str("username") ?? id, ratings: ratings, games: games,
                              tosViolation: obj.bool("tosViolation") ?? false)
    }

    // MARK: - Parsing

    private static func object(_ line: String) throws -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            throw LichessError.decoding("Not a JSON object: \(trimmed.prefix(200))")
        }
        return obj
    }

    static func parseEvent(_ line: String) throws -> LichessEvent? {
        guard let obj = try object(line) else { return nil }
        let type = obj.str("type") ?? ""
        switch type {
        case "challenge":
            guard let c = obj.dict("challenge"), let challenge = parseChallenge(c) else {
                throw LichessError.decoding("challenge event without challenge id")
            }
            return .challenge(challenge)
        case "challengeCanceled", "challengeDeclined":
            guard let c = obj.dict("challenge"), let id = c.str("id") else {
                throw LichessError.decoding("\(type) event without challenge id")
            }
            return type == "challengeCanceled" ? .challengeCanceled(id) : .challengeDeclined(id, reason: c.str("declineReasonKey"))
        case "gameStart", "gameFinish":
            guard let g = obj.dict("game"), let id = g.str("gameId") ?? g.str("id") else {
                throw LichessError.decoding("\(type) event without game id")
            }
            return type == "gameStart" ? .gameStart(id) : .gameFinish(id)
        default:
            return .other(type)
        }
    }

    private static func parseChallenge(_ c: [String: Any]) -> LichessChallenge? {
        guard let id = c.str("id") else { return nil }
        let tc = c.dict("timeControl")
        return LichessChallenge(
            id: id,
            challenger: c.dict("challenger").flatMap { parsePlayer($0) },
            variant: c.dict("variant")?.str("key") ?? "standard",
            rated: c.bool("rated") ?? false,
            speed: c.str("speed") ?? "",
            timeControl: tc?.str("type") ?? "unlimited",
            clockLimit: tc?.int("limit"),
            clockIncrement: tc?.int("increment"),
            daysPerTurn: tc?.int("daysPerTurn"),
            color: c.str("color") ?? "random",
            direction: c.str("direction"))
    }

    private static func parsePlayer(_ p: [String: Any]) -> LichessPlayer? {
        if let level = p.int("aiLevel") {
            return LichessPlayer(id: "lichess-ai-\(level)", name: "Lichess AI level \(level)", title: nil, rating: nil)
        }
        guard let id = p.str("id") ?? p.str("name")?.lowercased() else { return nil }
        return LichessPlayer(id: id, name: p.str("name") ?? p.str("username") ?? id,
                             title: p.str("title"), rating: p.int("rating"))
    }

    private static func parseState(_ s: [String: Any]) -> LichessGameState {
        let movesString = s.str("moves") ?? ""
        return LichessGameState(
            moves: movesString.split(whereSeparator: { $0 == " " }).map(String.init),
            wtime: s.int("wtime") ?? 0, btime: s.int("btime") ?? 0,
            winc: s.int("winc") ?? 0, binc: s.int("binc") ?? 0,
            status: s.str("status") ?? "started",
            winner: s.str("winner"),
            drawOffered: (s.bool("wdraw") ?? false) || (s.bool("bdraw") ?? false))
    }

    static func parseGameEvent(_ line: String) throws -> LichessGameEvent? {
        guard let obj = try object(line) else { return nil }
        let type = obj.str("type") ?? ""
        switch type {
        case "gameFull":
            guard let id = obj.str("id") else { throw LichessError.decoding("gameFull without id") }
            let unknown = LichessPlayer(id: "unknown", name: "Unknown")
            return .full(
                id: id,
                white: obj.dict("white").flatMap { parsePlayer($0) } ?? unknown,
                black: obj.dict("black").flatMap { parsePlayer($0) } ?? unknown,
                initialFen: obj.str("initialFen") ?? "startpos",
                rated: obj.bool("rated") ?? false,
                speed: obj.str("speed") ?? "",
                variant: obj.dict("variant")?.str("key") ?? "standard",
                state: parseState(obj.dict("state") ?? [:]))
        case "gameState":
            return .state(parseState(obj))
        case "chatLine":
            return .chat(username: obj.str("username") ?? "", text: obj.str("text") ?? "", room: obj.str("room") ?? "player")
        case "opponentGone":
            return .opponentGone(obj.bool("gone") ?? false)
        default:
            return .other(type)
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func int(_ k: String) -> Int? {
        if let n = self[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        return nil
    }
}
