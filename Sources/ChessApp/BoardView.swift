import SwiftUI
import ChessCore

struct BoardView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Square?
    @State private var pendingPromotion: (from: Square, to: Square)?
    /// The square whose piece is being dragged, and where the pointer is, in board coordinates.
    @State private var dragging: Square?
    @State private var dragLocation: CGPoint = .zero

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
            .coordinateSpace(name: "board")
            .overlay(alignment: .topLeading) {
                if let from = dragging, let piece = model.game.current.piece(at: from) {
                    pieceGlyph(piece, cell: cell)
                        .scaleEffect(1.12)
                        .position(dragLocation)
                        .allowsHitTesting(false)
                }
            }
            .gesture(drag(cell: cell))
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
                pieceGlyph(piece, cell: cell).opacity(dragging == square ? 0.25 : 1)
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

    private func pieceGlyph(_ piece: Piece, cell: CGFloat) -> some View {
        Text(piece.symbol)
            .font(.system(size: cell * 0.78))
            .foregroundStyle(piece.color == .white ? Color.white : Color.black)
            .shadow(color: piece.color == .white ? .black.opacity(0.9) : .white.opacity(0.35), radius: 0.8)
    }

    private var humanToMove: Bool {
        model.phase == .playing && model.game.current.sideToMove == model.humanColor
    }

    /// The square under a point in board coordinates, nil outside the board.
    private func square(at point: CGPoint, cell: CGFloat) -> Square? {
        let column = Int(point.x / cell), row = Int(point.y / cell)
        guard point.x >= 0, point.y >= 0, column < 8, row < 8 else { return nil }
        return square(at: row * 8 + column)
    }

    /// Drag a piece to a square; a short drag stays a click (minimum distance), so click-to-move keeps working.
    private func drag(cell: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("board"))
            .onChanged { value in
                if dragging == nil {
                    guard humanToMove, let from = square(at: value.startLocation, cell: cell),
                          model.game.current.piece(at: from)?.color == model.humanColor else { return }
                    dragging = from
                    selected = from
                }
                dragLocation = value.location
            }
            .onEnded { value in
                defer { dragging = nil }
                guard let from = dragging, let to = square(at: value.location, cell: cell), to != from else { return }
                if !attempt(from: from, to: to) { selected = nil }
            }
    }

    /// Plays from → to when legal (asking for the piece on a promotion); false when it is no legal move.
    @discardableResult
    private func attempt(from: Square, to: Square) -> Bool {
        let moves = model.game.current.legalMoves(from: from).filter { $0.to == to }
        guard let move = moves.first else { return false }
        selected = nil
        if moves.count > 1 { pendingPromotion = (from, to) } else { model.humanMove(move) }
        return true
    }

    private func tap(_ square: Square) {
        guard humanToMove else { return }
        let position = model.game.current
        if let from = selected, attempt(from: from, to: square) { return }
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
