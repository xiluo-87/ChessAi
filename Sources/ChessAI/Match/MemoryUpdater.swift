import Foundation
import ChessCore

/// After a game: the engine review (free), then one cheap call that rewrites the persona's notes and writes the
/// summary, and one cheap call that rewrites the opponent's dossier when the match may keep one.
public struct MemoryUpdater: Sendable {
    public var router: ModelRouter
    public var store: MemoryStore

    public init(router: ModelRouter, store: MemoryStore) {
        self.router = router
        self.store = store
    }

    public struct Outcome: Sendable {
        public var persona: PersonaProfile
        public var dossier: OpponentDossier?
        public var record: GameRecord
    }

    public func update(
        record: GameRecord, review: GameReview, persona: PersonaProfile, context: MatchContext
    ) async throws -> Outcome {
        var record = record
        record.review = review
        var persona = persona
        persona.record.add(record.result, as: record.personaColor)

        let reply = try await router.call(
            Prompts.personaUpdate(persona: persona, record: record, review: review), tier: .cheap, purpose: "persona notes")
        record.summary = reply.json["summary"] as? String
        if let style = reply.json["style"] as? String, !style.isEmpty { persona.style = style }
        persona.notes = Self.merge(
            reply.json["notes"] as? [[String: Any]] ?? [], into: persona.notes, game: record.id, budget: .persona)
        try store.save(persona)

        var dossier = store.dossier(context.opponent, persona: persona.id, in: context)
        if var current = dossier {
            current.record.add(record.result, as: record.personaColor)
            let reply = try await router.call(
                Prompts.opponentUpdate(dossier: current, persona: persona, record: record, review: review),
                tier: .cheap, purpose: "opponent notes")
            current.notes = Self.merge(
                reply.json["notes"] as? [[String: Any]] ?? [], into: current.notes, game: record.id, budget: .opponent)
            try store.save(current, persona: persona.id, in: context)
            dossier = current
        }
        try store.save(record)
        return Outcome(persona: persona, dossier: dossier, record: record)
    }

    /// The model's rewritten list, checked: unknown categories dropped, opening lines replayed from the start (an
    /// illegal line is cut where it breaks), evidence carried over from the old note with this game added when the
    /// game supports it, then trimmed to the budget. An empty answer keeps the old notes.
    static func merge(_ items: [[String: Any]], into old: [Note], game: String, budget: MemoryBudget) -> [Note] {
        guard !items.isEmpty else { return old }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let notes = items.compactMap { item -> Note? in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let category = (item["category"] as? String).flatMap(NoteCategory.init(rawValue:)),
                  let statement = item["statement"] as? String, !statement.isEmpty,
                  let rationale = item["rationale"] as? String, !rationale.isEmpty else { return nil }
            var evidence = previous[id]?.evidence ?? []
            if item["seenThisGame"] as? Bool == true, !evidence.contains(game) { evidence.append(game) }
            var line = (item["line"] as? [String]).map(legalPrefix)
            if line?.isEmpty == true { line = nil }
            return Note(
                id: id, category: category, statement: String(statement.prefix(140)),
                rationale: String(rationale.prefix(220)), line: category == .opening ? line : nil,
                side: (item["side"] as? String).flatMap(PieceColor.init(rawValue:)),
                confidence: item["confidence"] as? Double ?? previous[id]?.confidence ?? 0.3,
                evidence: evidence,
                updated: previous[id].map { $0.statement == statement && $0.rationale == rationale ? $0.updated : Date() } ?? Date())
        }
        return budget.trim(notes)
    }

    /// The longest legal start of a SAN line, in the engine's own SAN spelling.
    static func legalPrefix(_ sans: [String]) -> [String] {
        var position = Position.start
        var result: [String] = []
        for san in sans {
            guard let move = position.move(fromSAN: san) else { break }
            result.append(position.san(for: move))
            position = position.applying(move)
        }
        return result
    }
}

extension Record {
    public mutating func add(_ result: GameResult, as color: PieceColor) {
        switch result {
        case .draw: draws += 1
        case .whiteWins: if color == .white { wins += 1 } else { losses += 1 }
        case .blackWins: if color == .black { wins += 1 } else { losses += 1 }
        case .ongoing: break
        }
    }
}
