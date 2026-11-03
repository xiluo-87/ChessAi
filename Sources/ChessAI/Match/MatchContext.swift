import Foundation
import ChessCore

public enum MatchMode: String, Codable, Sendable {
    /// You against the persona. The persona studies you and keeps a dossier on you.
    case singlePlayer
    /// The persona against another model. Your dossier never enters such a match.
    case pvp
}

/// Who plays whom, and what memory the persona may use in this match.
public struct MatchContext: Codable, Sendable, Hashable {
    public var mode: MatchMode
    public var personaID: String
    public var opponent: OpponentID
    public var personaColor: PieceColor

    public enum PrivacyError: Error, LocalizedError {
        case humanNotesInPvP
        case humanOpponentInPvP

        public var errorDescription: String? {
            switch self {
            case .humanNotesInPvP: "a PvP match may not read or write a human player's notes"
            case .humanOpponentInPvP: "a PvP match is played against a model, not a human"
            }
        }
    }

    public init(mode: MatchMode, personaID: String, opponent: OpponentID, personaColor: PieceColor) throws {
        if mode == .pvp && opponent.isHuman { throw PrivacyError.humanOpponentInPvP }
        self.mode = mode
        self.personaID = personaID
        self.opponent = opponent
        self.personaColor = personaColor
    }

    /// The only dossier a match may read or write is its own opponent's, and never a human's in PvP.
    public func mayRead(_ other: OpponentID) -> Bool {
        guard other == opponent else { return false }
        return mode == .singlePlayer || !other.isHuman
    }
}
