import SwiftUI
import ChessCore
import ChessAI

// MARK: Game

struct GamePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("New as White") { model.newGame(humanPlays: .white) }
                    Button("New as Black") { model.newGame(humanPlays: .black) }
                    Spacer()
                    Button("Resign", role: .destructive) { model.resign() }
                        .disabled(!(model.phase == .playing || model.phase == .personaThinking))
                }
                .disabled(!model.engineReady)

                personaHeader
                if let record = model.lastRecord { PostGameView(record: record) }
                MoveListView()
                if !model.lastCandidates.isEmpty { candidates }
                CostView(calls: model.gameCalls)
            }
            .padding()
        }
    }

    private var personaHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.persona.name)  ·  \(model.persona.record.text)").font(.headline)
            Text(model.persona.style).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Candidates it weighed").font(.subheadline.bold())
            ForEach(model.lastCandidates, id: \.self) { c in
                Text("\(c.san)  \(c.score.description)   \(c.line.joined(separator: " "))")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }
}

struct MoveListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moves").font(.subheadline.bold())
            if model.notes.isEmpty { Text("No moves yet.").foregroundStyle(.secondary) }
            ForEach(model.notes, id: \.ply) { note in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.ply % 2 == 0 ? "\(note.ply / 2 + 1)." : "\(note.ply / 2 + 1)…")
                        .frame(width: 34, alignment: .trailing)
                        .foregroundStyle(.secondary)
                    Text(note.san).bold().frame(width: 56, alignment: .leading)
                    if note.byPersona {
                        SourceBadge(source: note.source)
                        Text(note.reason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    } else {
                        Text(model.settings.playerName).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(.callout, design: .monospaced))
            }
        }
    }
}

struct SourceBadge: View {
    var source: MoveSource?

    var body: some View {
        let (text, color): (String, Color) = switch source {
        case .book: ("book", .green)
        case .forced: ("forced", .gray)
        case .engine: ("engine", .blue)
        case .model: ("thought", .purple)
        case nil: ("", .clear)
        }
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PostGameView: View {
    var record: GameRecord

    var body: some View {
        GroupBox("After the game") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = record.summary { Text(summary) }
                if let review = record.review {
                    Text("Accuracy — persona: avg loss \(review.persona.averageLoss) cp, you: \(review.opponent.averageLoss) cp")
                        .font(.caption)
                    let worst = review.critical(byPersona: false, limit: 3)
                    if !worst.isEmpty {
                        Text("Your costliest moves").font(.caption.bold())
                        ForEach(worst, id: \.ply) { Text($0.label).font(.system(.caption, design: .monospaced)) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CostView: View {
    var calls: [CallRecord]

    var body: some View {
        let total = calls.reduce(ModelUsage()) { $0 + $1.usage }
        VStack(alignment: .leading, spacing: 4) {
            Text("Model use this game").font(.subheadline.bold())
            Text("\(calls.count) calls · \(calls.filter { $0.tier == .strong }.count) strong · in \(total.inputTokens) / cached \(total.cachedTokens) / out \(total.outputTokens) tokens"
                 + (total.costUSD.map { String(format: " · $%.4f list price", $0) } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(calls.suffix(6)) { call in
                Text("\(call.tier.rawValue) \(call.model) — \(call.purpose), \(String(format: "%.1f", call.seconds)) s")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: Memory

struct MemoryPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(model.persona.name)'s notes on its own play").font(.headline)
                    Text(model.persona.style).font(.callout).foregroundStyle(.secondary)
                }
                NotesList(notes: model.persona.notes, empty: "No notes yet: they form after the first game.")

                let dossier = model.dossier ?? model.store.dossier(
                    .human(model.settings.playerName), persona: model.persona.id,
                    in: try! MatchContext(mode: .singlePlayer, personaID: model.persona.id,
                                          opponent: .human(model.settings.playerName), personaColor: .black))
                Text("Its notes on you (\(model.settings.playerName), \(dossier?.record.text ?? "no games"))").font(.headline)
                Text("Used only in single-player games; never loaded in PvP.").font(.caption).foregroundStyle(.secondary)
                NotesList(notes: dossier?.notes ?? [], empty: "Nothing yet.")

                Button("Reset persona memory…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Erase all of \(model.persona.name)'s notes on its own play?", isPresented: $confirmReset) {
                        Button("Erase", role: .destructive) { model.resetPersonaMemory() }
                    }
            }
            .padding()
        }
    }
}

struct NotesList: View {
    var notes: [Note]
    var empty: String

    var body: some View {
        if notes.isEmpty {
            Text(empty).foregroundStyle(.secondary)
        }
        ForEach(notes) { note in
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(note.category.rawValue.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView(value: note.confidence).frame(width: 60)
                    Text("\(note.evidence.count) games").font(.caption2).foregroundStyle(.secondary)
                }
                Text(note.statement).font(.callout.bold())
                if let line = note.line, !line.isEmpty {
                    Text("\(note.side?.rawValue ?? ""): \(line.joined(separator: " "))")
                        .font(.system(.caption, design: .monospaced))
                }
                Text("Why: \(note.rationale)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
