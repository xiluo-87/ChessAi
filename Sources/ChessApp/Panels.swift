import SwiftUI
import ChessCore
import ChessAI

// MARK: Game

struct GamePanel: View {
    @EnvironmentObject var model: AppModel

    enum Pane: String, CaseIterable { case moves = "Moves", review = "Review" }
    @State private var pane = Pane.moves

    var body: some View {
        VStack(spacing: 0) {
            SubBar(selection: $pane, items: Pane.allCases) { $0.rawValue }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                header
                if model.engineMatchRunning { matchBanner }
                switch pane {
                case .moves:
                    // The move list takes the remaining height and scrolls on its own.
                    MoveListView()
                        .frame(maxHeight: .infinity)
                    if model.showThoughts, !model.lastCandidates.isEmpty { candidates }
                case .review:
                    if let record = model.lastRecord {
                        ScrollView { PostGameView(record: record) }
                            .scrollIndicators(.visible)
                            .frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "No review yet", systemImage: "text.magnifyingglass",
                            description: Text("\(model.persona.name) reviews each game when it ends."))
                            .frame(maxHeight: .infinity)
                    }
                }
                Divider()
                CostSummary(calls: model.gameCalls)
            }
            .padding()
        }
        // A finished game opens on its review; a new one on its moves.
        .onChange(of: model.lastRecord?.id) { _, id in pane = id == nil ? .moves : .review }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.persona.name).font(.headline)
            InfoButton(model.persona.style)
            Spacer()
            Label(model.offlineScore.text, systemImage: "person.fill").help("Score against you")
            Label(model.lichessScore.text, systemImage: "globe").help("Score on Lichess")
        }
        .font(.callout.monospacedDigit())
    }

    private var matchBanner: some View {
        HStack {
            Image(systemName: "flag.2.crossed")
            Text("Watching vs \(model.engineMatch?.label ?? "Stockfish")")
            Spacer()
            Button("Stop") { model.stopEngineMatch() }
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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

/// One line of model use, with the details in a popover.
struct CostSummary: View {
    var calls: [CallRecord]

    var body: some View {
        let cost = calls.reduce(ModelUsage()) { $0 + $1.usage }.costUSD
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text(calls.isEmpty ? "No model calls yet" : "\(calls.count) model calls" + (cost.map { String(format: " · $%.4f", $0) } ?? ""))
            InfoButton { CostView(calls: calls) }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Single player: moves only, White and Black on one line. With thoughts shown (PvP), one row per move with the
/// persona's full reason wrapped below it.
struct MoveListView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Moves").font(.subheadline.bold())
            if model.notes.isEmpty {
                Text("No moves yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: model.showThoughts ? 8 : 3) {
                            if model.showThoughts {
                                ForEach(model.notes, id: \.ply) { thoughtRow($0).id($0.ply) }
                            } else {
                                ForEach(pairs, id: \.number) { pairRow($0).id($0.number) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 12)
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: model.notes.count) { _, _ in
                        withAnimation { proxy.scrollTo(model.showThoughts ? model.notes.count - 1 : pairs.last?.number, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private struct Pair { var number: Int; var white: String?; var black: String? }

    /// Plies grouped by move number (a game started with Black to move leaves White's first cell empty).
    private var pairs: [Pair] {
        var result: [Pair] = []
        let offset = model.game.startPosition.sideToMove == .black ? 1 : 0
        for note in model.notes {
            let index = note.ply + offset
            let number = index / 2 + 1
            if result.last?.number != number { result.append(Pair(number: number)) }
            if index % 2 == 0 { result[result.count - 1].white = note.san } else { result[result.count - 1].black = note.san }
        }
        return result
    }

    private func pairRow(_ pair: Pair) -> some View {
        HStack(spacing: 10) {
            Text("\(pair.number).").frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
            Text(pair.white ?? "…").bold().frame(width: 80, alignment: .leading)
            Text(pair.black ?? "").bold().frame(width: 80, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 2)
        .background(pair.number % 2 == 0 ? Color.secondary.opacity(0.06) : .clear)
    }

    private func thoughtRow(_ note: MoveNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(note.ply % 2 == 0 ? "\(note.ply / 2 + 1)." : "\(note.ply / 2 + 1)…")
                    .frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                Text(note.san).bold()
                if note.byPersona { SourceBadge(source: note.source) }
            }
            .font(.system(.callout, design: .monospaced))
            if note.byPersona, let reason = note.reason, !reason.isEmpty {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 42)
                    .textSelection(.enabled)
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
    @EnvironmentObject var model: AppModel
    var record: GameRecord

    var body: some View {
        GroupBox("After the game") {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = record.summary { Text(summary) }
                if let review = record.review {
                    Text("Average loss — \(model.persona.name): \(review.persona.averageLoss) cp, \(record.opponent.isHuman ? "you" : record.opponent.name): \(review.opponent.averageLoss) cp")
                        .font(.caption)
                    let worst = review.critical(byPersona: false, limit: 3)
                    if !worst.isEmpty {
                        Text(record.opponent.isHuman ? "Your costliest moves" : "\(record.opponent.name)'s costliest moves").font(.caption.bold())
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
        let strong = calls.filter { $0.tier == .strong }.count
        VStack(alignment: .leading, spacing: 3) {
            Text("Model use this game").font(.subheadline.bold())
            Text("\(calls.count) calls, \(strong) strong" + (total.costUSD.map { String(format: " · $%.4f list price", $0) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            Text("Tokens: \(total.inputTokens) in · \(total.cachedTokens) cached · \(total.outputTokens) out")
                .font(.caption).foregroundStyle(.secondary)
            if !calls.isEmpty {
                DisclosureGroup("Latest calls") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(calls.suffix(6)) { call in
                            Text("\(call.tier.rawValue) \(call.model): \(call.purpose), \(String(format: "%.1f", call.seconds)) s")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        // Takes the height it needs: the move list above gives way, not these lines.
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }
}

// MARK: Memory

struct MemoryPanel: View {
    @EnvironmentObject var model: AppModel

    enum Pane: Hashable { case own, opponent }
    @State private var pane = Pane.own

    var body: some View {
        VStack(spacing: 0) {
            SubBar(selection: $pane, items: [.own, .opponent]) {
                $0 == .own ? "Own play" : "On \(model.settings.playerName)"
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch pane {
                    case .own:
                        HStack(spacing: 6) {
                            Text("\(model.persona.name)'s notes on its own play").font(.headline)
                            InfoButton(model.persona.style)
                        }
                        NotesList(notes: model.persona.notes, empty: "No notes yet: they form after the first game.")
                    case .opponent:
                        let dossier = model.dossier ?? model.store.dossier(
                            .human(model.settings.playerName), persona: model.persona.id,
                            in: try! MatchContext(mode: .singlePlayer, personaID: model.persona.id,
                                                  opponent: .human(model.settings.playerName), personaColor: .black))
                        HStack(spacing: 6) {
                            Text("Its notes on \(model.settings.playerName)").font(.headline)
                            Text(dossier?.record.text ?? "no games").font(.callout).foregroundStyle(.secondary)
                            InfoButton("Used only in single-player games against you; never loaded in PvP or on Lichess.")
                        }
                        NotesList(notes: dossier?.notes ?? [], empty: "Nothing yet.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .scrollIndicators(.visible)
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
