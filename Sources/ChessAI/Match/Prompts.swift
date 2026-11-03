import Foundation
import ChessCore
import ChessEngine

/// Every prompt the app sends. Kept short: each token here is paid on every call.
enum Prompts {
    // MARK: During the match (strong tier)

    static func matchSystem(persona: PersonaProfile, dossier: OpponentDossier?, context: MatchContext) -> String {
        var text = """
            You are \(persona.name), a chess player. \(persona.style)
            An engine has already filtered the position to sound candidate moves; you choose the one that fits your \
            style, your plan and the opponent best. Be brief.

            Your notes on your own play:
            \(persona.notes.isEmpty ? "(none yet: you are still forming your preferences)" : NoteRenderer.render(persona.notes))
            """
        if let dossier, !dossier.notes.isEmpty {
            text += """


                Your notes on this opponent (\(dossier.opponent.displayName), record \(dossier.record.text)):
                \(NoteRenderer.render(dossier.notes))
                """
        }
        return text
    }

    static let moveSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "move": ["type": "string", "description": "one candidate, in SAN exactly as listed"],
            "reason": ["type": "string", "maxLength": 160, "description": "why, at most 20 words"],
            "plan": ["type": "string", "maxLength": 120, "description": "your plan for the next moves, at most 12 words"],
        ],
        "required": ["move", "reason", "plan"],
        "additionalProperties": false,
    ]

    static func moveRequest(system: String, game: Game, candidates: [Candidate], plan: String, context: MatchContext) -> ModelRequest {
        let recent = game.sans.enumerated().suffix(10).map { ply, san in
            ply % 2 == 0 ? "\(ply / 2 + 1). \(san)" : (ply == game.sans.count - 10 ? "\(ply / 2 + 1)... \(san)" : san)
        }.joined(separator: " ")
        let list = candidates.enumerated().map { index, c in
            "\(index + 1). \(c.san) \(c.score.description) — line: \(c.line.joined(separator: " "))"
        }.joined(separator: "\n")
        let prompt = """
            Move \(game.moves.count / 2 + 1), you play \(context.personaColor.rawValue). FEN: \(game.current.fen)
            Recent moves: \(recent.isEmpty ? "none" : recent)
            Your plan so far: \(plan.isEmpty ? "none yet" : plan)
            Candidates (eval from your side):
            \(list)
            """
        return ModelRequest(system: system, prompt: prompt, schema: moveSchema, timeout: 90)
    }

    // MARK: After the game (cheap tier)

    static func noteSchema(categories: [NoteCategory], maxItems: Int) -> [String: Any] {
        [
            "type": "array",
            "maxItems": maxItems,
            "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "short kebab-case id; keep an existing note's id"],
                    "category": ["type": "string", "enum": categories.map(\.rawValue)],
                    "statement": ["type": "string", "maxLength": 140],
                    "rationale": ["type": "string", "maxLength": 220,
                                  "description": "the evidence from games that made this worth noting"],
                    "line": ["type": "array", "items": ["type": "string"], "maxItems": 12,
                             "description": "opening notes only: SAN moves from the start position"],
                    "side": ["type": "string", "enum": ["white", "black"]],
                    "confidence": ["type": "number", "minimum": 0, "maximum": 1],
                    "seenThisGame": ["type": "boolean", "description": "this game is evidence for the note"],
                ],
                "required": ["id", "category", "statement", "rationale", "confidence", "seenThisGame"],
                "additionalProperties": false,
            ] as [String: Any],
        ]
    }

    static func personaUpdate(persona: PersonaProfile, record: GameRecord, review: GameReview) -> ModelRequest {
        let budget = MemoryBudget.persona
        let choices = record.notes.filter { $0.byPersona && $0.source == .model }.map { note -> String in
            let judged = review.plies.first { $0.ply == note.ply }
            return "\(note.ply / 2 + 1). \(note.san) [\(judged?.judgement.rawValue ?? "?")] — \(note.reason ?? "")"
        }
        let mistakes = review.critical(byPersona: true).map(\.label)
        let result = record.result == .draw ? "draw"
            : (record.result == .whiteWins) == (record.personaColor == .white) ? "won" : "lost"

        let system = """
            You maintain the self-knowledge of a chess persona: a bounded list of notes, rewritten after every game, \
            never appended to. Keep notes the game supports or does not touch; merge overlapping ones; raise confidence \
            when the game confirms a note and lower it when it contradicts it; drop notes below 0.2. Add a note only \
            for a pattern with evidence. Every note's rationale states the evidence (game moments, results), not a \
            restatement. Opening notes carry the line in SAN from the start position and the side. Notes are about \
            the persona's own play only: never describe the opponent. At most \(budget.maxNotes) notes.
            """
        let prompt = """
            Persona: \(persona.name). Style: \(persona.style). Record before this game: \(persona.record.text).
            Current notes (JSON): \(json(persona.notes))

            Game \(record.id): \(persona.name) played \(record.personaColor.rawValue) and \(result) (\(record.result.rawValue)\
            \(record.end.map { ", \($0.rawValue)" } ?? "")).
            Moves: \(sanText(record))
            Own play: \(review.persona.text)
            Own costliest moves: \(mistakes.isEmpty ? "none" : mistakes.joined(separator: "; "))
            Own deliberate choices and how they turned out:
            \(choices.isEmpty ? "none" : choices.joined(separator: "\n"))

            Return the full updated notes, the style refined in at most two sentences, and a summary of the game \
            from the persona's view in at most 80 words.
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "summary": ["type": "string", "maxLength": 600],
                "style": ["type": "string", "maxLength": 300],
                "notes": noteSchema(categories: [.opening, .strategy, .principle, .weakness], maxItems: budget.maxNotes),
            ],
            "required": ["summary", "style", "notes"],
            "additionalProperties": false,
        ]
        return ModelRequest(system: system, prompt: prompt, schema: schema, timeout: 150)
    }

    static func opponentUpdate(dossier: OpponentDossier, persona: PersonaProfile, record: GameRecord, review: GameReview) -> ModelRequest {
        let budget = MemoryBudget.opponent
        let mistakes = review.critical(byPersona: false, limit: 5).map(\.label)
        let system = """
            You keep a chess persona's scouting file on one opponent: a bounded list of notes, rewritten after every \
            game, never appended to. Record the opponent's openings (line in SAN from the start, with the opponent's \
            side), recurring tendencies, weaknesses, and concrete exploits the persona should aim for. Keep notes the \
            game supports or does not touch, merge overlaps, raise or lower confidence by the evidence, drop notes \
            below 0.2. Every rationale states the evidence (game moments, statistics). At most \(budget.maxNotes) notes.
            """
        let prompt = """
            Opponent: \(dossier.opponent.displayName), record against \(persona.name): \(dossier.record.text).
            Current notes (JSON): \(json(dossier.notes))

            Game \(record.id): the opponent played \(record.personaColor.opposite.rawValue); result \(record.result.rawValue)\
            \(record.end.map { " (\($0.rawValue))" } ?? "").
            Moves: \(sanText(record))
            Opponent's play: \(review.opponent.text)
            Opponent's costliest moves: \(mistakes.isEmpty ? "none" : mistakes.joined(separator: "; "))

            Return the full updated notes.
            """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["notes": noteSchema(categories: [.opening, .tendency, .weakness, .exploit], maxItems: budget.maxNotes)],
            "required": ["notes"],
            "additionalProperties": false,
        ]
        return ModelRequest(system: system, prompt: prompt, schema: schema, timeout: 150)
    }

    private static func sanText(_ record: GameRecord) -> String {
        record.notes.map { $0.ply % 2 == 0 ? "\($0.ply / 2 + 1). \($0.san)" : $0.san }.joined(separator: " ")
    }

    /// Notes without dates and evidence ids: the model needs the content, not the bookkeeping.
    private static func json(_ notes: [Note]) -> String {
        let slim: [[String: Any]] = notes.map { note in
            var item: [String: Any] = [
                "id": note.id, "category": note.category.rawValue, "statement": note.statement,
                "rationale": note.rationale, "confidence": (note.confidence * 100).rounded() / 100,
                "games": note.evidence.count,
            ]
            if let line = note.line { item["line"] = line }
            if let side = note.side { item["side"] = side.rawValue }
            return item
        }
        let data = (try? JSONSerialization.data(withJSONObject: slim, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
