import Foundation
import ChessCore

public enum NoteCategory: String, Codable, Sendable, CaseIterable {
    /// An opening the player chooses, with its line in SAN; the persona's own lines become its book.
    case opening
    /// A plan or structure the player prefers (e.g. "trade into endgames when ahead").
    case strategy
    /// A rule the player trusts when choosing between near-equal moves.
    case principle
    /// Something the player gets wrong.
    case weakness
    /// A habit seen in an opponent (e.g. "castles late", "grabs pawns").
    case tendency
    /// How to use an opponent's weakness or tendency.
    case exploit
}

/// One remembered preference or observation. Every note carries why it was noted: the rationale is the evidence
/// from games, not a restatement.
public struct Note: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var category: NoteCategory
    public var statement: String
    public var rationale: String
    /// Opening notes: the line in SAN from the start position, and the side that plays it.
    public var line: [String]?
    public var side: PieceColor?
    /// 0...1: how sure the note is, raised by confirming games and lowered by contradicting ones.
    public var confidence: Double
    /// The games the note rests on, newest last, at most `MemoryBudget.evidencePerNote`.
    public var evidence: [String]
    public var updated: Date

    public init(
        id: String, category: NoteCategory, statement: String, rationale: String, line: [String]? = nil,
        side: PieceColor? = nil, confidence: Double, evidence: [String] = [], updated: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.statement = statement
        self.rationale = rationale
        self.line = line
        self.side = side
        self.confidence = confidence
        self.evidence = evidence
        self.updated = updated
    }
}

public struct Record: Codable, Sendable, Hashable {
    public var wins = 0, draws = 0, losses = 0
    public init() {}
    public var games: Int { wins + draws + losses }
    public var text: String { "+\(wins) =\(draws) -\(losses)" }
}

/// The persona: who it is and what it has learned about its own play. Holds nothing about any opponent.
public struct PersonaProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// One or two sentences: the character it starts from, refined by its notes.
    public var style: String
    public var notes: [Note]
    public var record = Record()
    public var created = Date()

    public init(id: String, name: String, style: String, notes: [Note] = []) {
        self.id = id
        self.name = name
        self.style = style
        self.notes = notes
    }

    /// The persona's opening lines for one side, most confident first.
    public func repertoire(for side: PieceColor) -> [Note] {
        notes.filter { $0.category == .opening && $0.side == side && !($0.line ?? []).isEmpty }
            .sorted { $0.confidence > $1.confidence }
    }
}

/// Who an opponent is. Human ids and model ids live in separate namespaces so a PvP match can never load a human's
/// dossier by accident.
public enum OpponentID: Codable, Sendable, Hashable {
    case human(String)
    case model(String)
    /// An opponent on Lichess, by username: a human or a bot elsewhere, never the local player's notes.
    case lichess(String)

    public var key: String {
        switch self {
        case .human(let name): "human-\(Self.slug(name))"
        case .model(let name): "model-\(Self.slug(name))"
        case .lichess(let name): "lichess-\(Self.slug(name))"
        }
    }

    public var isHuman: Bool { if case .human = self { true } else { false } }
    public var isLichess: Bool { if case .lichess = self { true } else { false } }

    public var displayName: String {
        switch self {
        case .human(let name), .model(let name): name
        case .lichess(let name): "\(name) (Lichess)"
        }
    }

    static func slug(_ text: String) -> String {
        let allowed = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }
}

/// What the persona knows about one opponent: their habits and how to beat them.
public struct OpponentDossier: Codable, Sendable, Hashable {
    public var opponent: OpponentID
    public var notes: [Note] = []
    /// From the persona's side.
    public var record = Record()

    public init(opponent: OpponentID) { self.opponent = opponent }
}

/// Size limits of the memory documents. A document is rewritten after each game to fit, never appended to.
public struct MemoryBudget: Codable, Sendable, Hashable {
    public var maxNotes: Int
    /// Rough tokens of the rendered document in a prompt (characters / 4).
    public var maxTokens: Int
    public var evidencePerNote: Int

    public init(maxNotes: Int = 14, maxTokens: Int = 1_200, evidencePerNote: Int = 5) {
        self.maxNotes = maxNotes
        self.maxTokens = maxTokens
        self.evidencePerNote = evidencePerNote
    }

    public static let persona = MemoryBudget(maxNotes: 16, maxTokens: 1_400)
    public static let opponent = MemoryBudget(maxNotes: 12, maxTokens: 1_000)

    public static func tokens(_ text: String) -> Int { (text.count + 3) / 4 }

    /// The notes trimmed to the budget: duplicates of an id merged away, evidence shortened, then the least confident
    /// notes dropped until the rendered text fits.
    public func trim(_ notes: [Note]) -> [Note] {
        var seen = Set<String>()
        var kept = notes.filter { seen.insert($0.id).inserted }.map { note -> Note in
            var note = note
            note.confidence = min(1, max(0, note.confidence))
            note.evidence = Array(note.evidence.suffix(evidencePerNote))
            return note
        }
        kept.sort { $0.confidence > $1.confidence }
        if kept.count > maxNotes { kept = Array(kept.prefix(maxNotes)) }
        while kept.count > 1, Self.tokens(NoteRenderer.render(kept)) > maxTokens { kept.removeLast() }
        return kept
    }
}

public enum NoteRenderer {
    /// Compact lines for prompts: category, statement, opening line, why, and confidence.
    public static func render(_ notes: [Note]) -> String {
        notes.map { note in
            var line = "- [\(note.category.rawValue)] \(note.statement)"
            if let moves = note.line, !moves.isEmpty {
                line += " (\(note.side?.rawValue ?? "either"): \(moves.joined(separator: " ")))"
            }
            line += " — why: \(note.rationale) (conf \(String(format: "%.1f", note.confidence)), \(note.evidence.count) games)"
            return line
        }.joined(separator: "\n")
    }
}
