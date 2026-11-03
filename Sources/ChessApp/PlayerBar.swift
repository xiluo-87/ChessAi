import SwiftUI
import ChessCore

/// The player above or below the board, with the Lichess clock while a Lichess game is on. The side to move's clock
/// counts down locally between server updates.
struct PlayerBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lichess: LichessController
    var top: Bool

    var body: some View {
        let color = top ? model.bottomColor.opposite : model.bottomColor
        let toMove = model.game.current.sideToMove == color && model.game.end == nil
        HStack(spacing: 10) {
            Circle()
                .fill(color == .white ? Color.white : Color.black)
                .overlay(Circle().stroke(Color.secondary, lineWidth: 1))
                .frame(width: 12, height: 12)
            Text(name(for: color)).font(.headline)
            if let rating = rating(for: color) {
                Text(verbatim: String(rating)).foregroundStyle(.secondary)
            } else if model.boardIsExternal, color == model.personaSide {
                Text("unrated").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            if lichess.currentGame != nil, model.phase == .watching {
                clock(for: color, running: toMove)
            }
        }
        // A fixed height, so the board keeps its size when the clocks appear.
        .frame(maxWidth: 560, minHeight: 34, maxHeight: 34)
        .padding(.horizontal, 4)
    }

    private func name(for color: PieceColor) -> String {
        if color == model.personaSide { return model.persona.name }
        if model.boardIsExternal { return lichess.opponent?.name ?? "Opponent" }
        if let match = model.engineMatch { return match.label }
        return model.settings.playerName
    }

    private func rating(for color: PieceColor) -> Int? {
        guard model.boardIsExternal else { return nil }
        return color == model.personaSide ? lichess.personaRating : lichess.opponent?.rating
    }

    private func clock(for color: PieceColor, running: Bool) -> some View {
        let base = color == .white ? lichess.clocks.white : lichess.clocks.black
        return TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let elapsed = running ? Int(context.date.timeIntervalSince(lichess.clockStamp) * 1000) : 0
            let ms = max(0, base - elapsed)
            Text(Self.format(ms))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(running ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(ms < 20_000 && running ? Color.red : Color.primary)
        }
    }

    static func format(_ ms: Int) -> String {
        guard ms < 86_400_000 else { return "∞" }
        let seconds = ms / 1000
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        if ms < 10_000 { return String(format: "0:%02d.%d", seconds, ms / 100 % 10) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
