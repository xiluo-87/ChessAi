import Foundation

public struct EngineScore: Codable, Sendable, Hashable {
    /// Centipawns from the side-to-move's perspective, as UCI reports it.
    public var centipawns: Int?
    /// Moves to mate, negative if the side to move gets mated.
    public var mate: Int?

    public init(centipawns: Int?, mate: Int?) {
        self.centipawns = centipawns
        self.mate = mate
    }

    /// Centipawns, or mate mapped to ±(100_000 - abs(mate)*100).
    public var normalized: Int {
        if let m = mate {
            let magnitude = 100_000 - abs(m) * 100
            return m < 0 ? -magnitude : magnitude
        }
        return centipawns ?? 0
    }

    /// The same score from the other side's perspective.
    public func flipped() -> EngineScore {
        EngineScore(centipawns: centipawns.map { -$0 }, mate: mate.map { -$0 })
    }

    public var description: String {
        if let m = mate { return "#\(m)" }
        let cp = centipawns ?? 0
        let sign = cp < 0 ? "-" : "+"
        let a = abs(cp)
        return "\(sign)\(a / 100).\(String(format: "%02d", a % 100))"
    }
}

public struct EngineLine: Codable, Sendable, Hashable {
    public var move: String
    public var score: EngineScore
    public var pv: [String]
    public var depth: Int

    public init(move: String, score: EngineScore, pv: [String], depth: Int) {
        self.move = move
        self.score = score
        self.pv = pv
        self.depth = depth
    }
}

public struct EngineLimits: Sendable {
    public var depth: Int?
    public var movetimeMs: Int?
    public init(depth: Int? = nil, movetimeMs: Int? = nil) {
        self.depth = depth
        self.movetimeMs = movetimeMs
    }
}

public enum EngineError: Error {
    case notFound
    case launchFailed(String)
    case noResponse(String)
    case terminated
}
