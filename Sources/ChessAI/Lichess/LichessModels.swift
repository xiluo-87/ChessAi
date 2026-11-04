import Foundation

public struct LichessAccount: Sendable, Hashable {
    public var id: String
    public var username: String
    public var title: String?
    /// Rating per speed ("rapid", "classical", …), from the account's perfs.
    public var ratings: [String: Int]
    public var isBot: Bool { title == "BOT" }

    public init(id: String, username: String, title: String? = nil, ratings: [String: Int] = [:]) {
        self.id = id
        self.username = username
        self.title = title
        self.ratings = ratings
    }
}

public struct LichessPlayer: Sendable, Hashable {
    public var id: String
    public var name: String
    public var title: String?
    public var rating: Int?
    public var isBot: Bool { title == "BOT" }

    public init(id: String, name: String, title: String? = nil, rating: Int? = nil) {
        self.id = id
        self.name = name
        self.title = title
        self.rating = rating
    }
}

public struct LichessChallenge: Sendable, Hashable {
    public var id: String
    public var challenger: LichessPlayer?
    public var variant: String
    public var rated: Bool
    public var speed: String
    /// "clock" | "correspondence" | "unlimited"
    public var timeControl: String
    public var clockLimit: Int?
    public var clockIncrement: Int?
    public var daysPerTurn: Int?
    public var color: String
    public var direction: String?

    public init(id: String, challenger: LichessPlayer? = nil, variant: String = "standard", rated: Bool = false,
                speed: String = "", timeControl: String = "unlimited", clockLimit: Int? = nil,
                clockIncrement: Int? = nil, daysPerTurn: Int? = nil, color: String = "random",
                direction: String? = nil) {
        self.id = id
        self.challenger = challenger
        self.variant = variant
        self.rated = rated
        self.speed = speed
        self.timeControl = timeControl
        self.clockLimit = clockLimit
        self.clockIncrement = clockIncrement
        self.daysPerTurn = daysPerTurn
        self.color = color
        self.direction = direction
    }
}

public enum LichessEvent: Sendable, Hashable {
    case challenge(LichessChallenge)
    case challengeCanceled(String)
    /// `reason` is Lichess's key for why (`tooFast`, `later`, `noBot`, …), when it sends one.
    case challengeDeclined(String, reason: String?)
    case gameStart(String)
    case gameFinish(String)
    case other(String)
}

public struct LichessGameState: Sendable, Hashable {
    public var moves: [String]
    public var wtime: Int
    public var btime: Int
    public var winc: Int
    public var binc: Int
    public var status: String
    public var winner: String?
    public var drawOffered: Bool
    public var isOver: Bool { status != "created" && status != "started" }

    public init(moves: [String] = [], wtime: Int = 0, btime: Int = 0, winc: Int = 0, binc: Int = 0,
                status: String = "started", winner: String? = nil, drawOffered: Bool = false) {
        self.moves = moves
        self.wtime = wtime
        self.btime = btime
        self.winc = winc
        self.binc = binc
        self.status = status
        self.winner = winner
        self.drawOffered = drawOffered
    }
}

public enum LichessGameEvent: Sendable, Hashable {
    case full(id: String, white: LichessPlayer, black: LichessPlayer, initialFen: String, rated: Bool,
              speed: String, variant: String, state: LichessGameState)
    case state(LichessGameState)
    case chat(username: String, text: String, room: String)
    case opponentGone(Bool)
    case other(String)
}

public enum LichessError: Error, LocalizedError {
    case unauthorized
    case rateLimited
    case http(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Lichess rejected the API token (401)."
        case .rateLimited: return "Lichess rate limit hit (429); wait a minute before retrying."
        case .http(let code, let message): return "Lichess HTTP \(code): \(message)"
        case .decoding(let message): return "Could not decode Lichess response: \(message)"
        }
    }
}

/// One bot from the online list, with its rating per speed ("blitz", "rapid", "classical", "correspondence", …).
public struct LichessBotInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var username: String
    public var ratings: [String: Int]
    public var games: [String: Int]
    public var tosViolation: Bool

    public init(id: String, username: String, ratings: [String: Int], games: [String: Int], tosViolation: Bool = false) {
        self.id = id
        self.username = username
        self.ratings = ratings
        self.games = games
        self.tosViolation = tosViolation
    }
}
