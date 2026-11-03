import Foundation
import ChessCore

/// How the persona chose one of its moves. Every source but `model` is free.
public enum MoveSource: String, Codable, Sendable {
    case book, forced, engine, model
}

/// The note taken for one ply while the game runs: the persona's choice with its reason, or the opponent's move.
public struct MoveNote: Codable, Sendable, Hashable {
    public var ply: Int
    public var san: String
    public var byPersona: Bool
    public var source: MoveSource?
    public var reason: String?
    /// The engine's evaluation before the move, from White's side, when it was computed during play.
    public var evalBefore: Int?

    public init(ply: Int, san: String, byPersona: Bool, source: MoveSource? = nil, reason: String? = nil, evalBefore: Int? = nil) {
        self.ply = ply
        self.san = san
        self.byPersona = byPersona
        self.source = source
        self.reason = reason
        self.evalBefore = evalBefore
    }
}

public struct GameRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var personaID: String
    public var opponent: OpponentID
    public var personaColor: PieceColor
    public var result: GameResult
    public var end: GameEnd?
    public var pgn: String
    public var notes: [MoveNote]
    public var review: GameReview?
    public var summary: String?
    public var usage: ModelUsage
    public var calls: Int

    public init(
        id: String, date: Date, personaID: String, opponent: OpponentID, personaColor: PieceColor,
        result: GameResult, end: GameEnd?, pgn: String, notes: [MoveNote], usage: ModelUsage = ModelUsage(), calls: Int = 0
    ) {
        self.id = id
        self.date = date
        self.personaID = personaID
        self.opponent = opponent
        self.personaColor = personaColor
        self.result = result
        self.end = end
        self.pgn = pgn
        self.notes = notes
        self.usage = usage
        self.calls = calls
    }
}

/// JSON files under Application Support/ChessAi:
/// personas/<id>/profile.json, personas/<id>/opponents/<opponent key>.json, games/<id>.json.
public final class MemoryStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessAi", isDirectory: true)
    }

    public static let defaultPersona = PersonaProfile(
        id: "json-bourne", name: "JSON Bourne",
        style: "A calm, methodical player who likes harmonious development, prefers the initiative over material, "
            + "and learns from every game.")

    /// The first persona was called Kasia (id "kasia"). Its folder, with its notes and its dossiers, moves to the
    /// default persona, and its games are relabelled. Does nothing once moved, or when there is nothing to move.
    public func migrateLegacyPersona() {
        let fm = FileManager.default
        let old = root.appendingPathComponent("personas/kasia")
        let new = root.appendingPathComponent("personas/\(Self.defaultPersona.id)")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            return
        }
        if var persona = persona(Self.defaultPersona.id) {
            persona.id = Self.defaultPersona.id
            if persona.name == "Kasia" { persona.name = Self.defaultPersona.name }
            try? save(persona)
        }
        for var game in games() where game.personaID == "kasia" {
            game.personaID = Self.defaultPersona.id
            try? save(game)
        }
    }

    // MARK: Personas

    public func personas() -> [PersonaProfile] {
        let folder = root.appendingPathComponent("personas")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return ids.compactMap { load(PersonaProfile.self, at: personaFile($0)) }.sorted { $0.created < $1.created }
    }

    public func persona(_ id: String) -> PersonaProfile? { load(PersonaProfile.self, at: personaFile(id)) }

    public func save(_ persona: PersonaProfile) throws {
        var persona = persona
        persona.notes = MemoryBudget.persona.trim(persona.notes)
        try write(persona, to: personaFile(persona.id))
    }

    // MARK: Opponents

    /// Loading a dossier needs the match context: a PvP match is refused any human's dossier.
    public func dossier(_ opponent: OpponentID, persona: String, in context: MatchContext) -> OpponentDossier? {
        guard context.mayRead(opponent) else { return nil }
        return load(OpponentDossier.self, at: dossierFile(opponent, persona: persona)) ?? OpponentDossier(opponent: opponent)
    }

    public func save(_ dossier: OpponentDossier, persona: String, in context: MatchContext) throws {
        guard context.mayRead(dossier.opponent) else { throw MatchContext.PrivacyError.humanNotesInPvP }
        var dossier = dossier
        dossier.notes = MemoryBudget.opponent.trim(dossier.notes)
        try write(dossier, to: dossierFile(dossier.opponent, persona: persona))
    }

    // MARK: Games

    public func save(_ game: GameRecord) throws {
        try write(game, to: root.appendingPathComponent("games/\(game.id).json"))
    }

    public func games(persona: String? = nil) -> [GameRecord] {
        let folder = root.appendingPathComponent("games")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { load(GameRecord.self, at: folder.appendingPathComponent($0)) }
            .filter { persona == nil || $0.personaID == persona }
            .sorted { $0.date > $1.date }
    }

    // MARK: Files

    private func personaFile(_ id: String) -> URL {
        root.appendingPathComponent("personas/\(id)/profile.json")
    }

    private func dossierFile(_ opponent: OpponentID, persona: String) -> URL {
        root.appendingPathComponent("personas/\(persona)/opponents/\(opponent.key).json")
    }

    private func load<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
