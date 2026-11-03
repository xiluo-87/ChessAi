import SwiftUI
import ChessCore

struct BoardView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Square?
    @State private var pendingPromotion: (from: Square, to: Square)?

    private let light = Color(red: 0.93, green: 0.89, blue: 0.80)
    private let dark = Color(red: 0.55, green: 0.42, blue: 0.32)

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let cell = size / 8
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { column in
                            let square = square(at: row * 8 + column)
                            squareView(square, cell: cell)
                                .frame(width: cell, height: cell)
                                .onTapGesture { tap(square) }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .confirmationDialog("Promote to", isPresented: Binding(
            get: { pendingPromotion != nil }, set: { if !$0 { pendingPromotion = nil } })
        ) {
            ForEach([PieceKind.queen, .rook, .bishop, .knight], id: \.self) { kind in
                Button(kind.name) {
                    if let p = pendingPromotion { model.humanMove(Move(from: p.from, to: p.to, promotion: kind)) }
                    pendingPromotion = nil
                }
            }
        }
    }

    /// Display index (row-major from the top-left) to board square, flipped when the human plays Black.
    private func square(at index: Int) -> Square {
        let row = index / 8, column = index % 8
        return model.humanColor == .white
            ? Squares.make(file: column, rank: 7 - row)
            : Squares.make(file: 7 - column, rank: row)
    }

    @ViewBuilder
    private func squareView(_ square: Square, cell: CGFloat) -> some View {
        let position = model.game.current
        let isLight = (Squares.file(square) + Squares.rank(square)) % 2 == 1
        let lastMove = model.game.moves.last
        let targets = selected.map { position.legalMoves(from: $0).map(\.to) } ?? []
        ZStack {
            Rectangle().fill(isLight ? light : dark)
            if lastMove?.from == square || lastMove?.to == square {
                Rectangle().fill(Color.yellow.opacity(0.35))
            }
            if selected == square {
                Rectangle().fill(Color.accentColor.opacity(0.35))
            }
            if position.isInCheck(), position.piece(at: square) == Piece(.king, position.sideToMove) {
                Circle().fill(Color.red.opacity(0.45)).padding(cell * 0.06)
            }
            if let piece = position.piece(at: square) {
                Text(piece.symbol)
                    .font(.system(size: cell * 0.78))
                    .foregroundStyle(piece.color == .white ? Color.white : Color.black)
                    .shadow(color: piece.color == .white ? .black.opacity(0.9) : .white.opacity(0.35), radius: 0.8)
            }
            if targets.contains(square) {
                Circle()
                    .fill(Color.black.opacity(0.22))
                    .frame(width: position.piece(at: square) == nil ? cell * 0.3 : cell * 0.9)
            }
            coordinates(square, cell: cell, isLight: isLight)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func coordinates(_ square: Square, cell: CGFloat, isLight: Bool) -> some View {
        let bottomRank = model.humanColor == .white ? 0 : 7
        let leftFile = model.humanColor == .white ? 0 : 7
        let color = (isLight ? dark : light).opacity(0.9)
        ZStack {
            if Squares.rank(square) == bottomRank {
                Text(String(Squares.name(square).prefix(1)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if Squares.file(square) == leftFile {
                Text(String(Squares.name(square).suffix(1)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .font(.system(size: cell * 0.14, weight: .semibold))
        .foregroundStyle(color)
        .padding(cell * 0.04)
    }

    private func tap(_ square: Square) {
        guard model.phase == .playing else { return }
        let position = model.game.current
        guard position.sideToMove == model.humanColor else { return }
        if let from = selected {
            let moves = position.legalMoves(from: from).filter { $0.to == square }
            if moves.count > 1 {
                pendingPromotion = (from, square)
                selected = nil
                return
            }
            if let move = moves.first {
                model.humanMove(move)
                selected = nil
                return
            }
        }
        if let piece = position.piece(at: square), piece.color == model.humanColor {
            selected = selected == square ? nil : square
        } else {
            selected = nil
        }
    }
}

extension PieceKind {
    var name: String {
        switch self {
        case .pawn: "Pawn"
        case .knight: "Knight"
        case .bishop: "Bishop"
        case .rook: "Rook"
        case .queen: "Queen"
        case .king: "King"
        }
    }
}
