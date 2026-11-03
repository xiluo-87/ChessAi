import XCTest
import ChessCore
@testable import ChessAI

final class PrivacyTests: XCTestCase {
    func testPvPWithHumanOpponentThrows() {
        XCTAssertThrowsError(try MatchContext(mode: .pvp, personaID: "kasia", opponent: .human("alice"), personaColor: .white)) {
            XCTAssertEqual($0 as? MatchContext.PrivacyError, MatchContext.PrivacyError.humanOpponentInPvP)
        }
        XCTAssertNoThrow(try MatchContext(mode: .pvp, personaID: "kasia", opponent: .model("gpt"), personaColor: .black))
        XCTAssertNoThrow(try MatchContext(mode: .singlePlayer, personaID: "kasia", opponent: .human("alice"), personaColor: .black))
    }

    func testMayReadOnlyOwnOpponent() {
        let single = singlePlayer(.human("alice"))
        XCTAssertTrue(single.mayRead(.human("alice")))
        XCTAssertFalse(single.mayRead(.human("bob")))
        XCTAssertFalse(single.mayRead(.model("alice")))

        let match = pvp(.model("gpt"))
        XCTAssertTrue(match.mayRead(.model("gpt")))
        XCTAssertFalse(match.mayRead(.model("other")))
        XCTAssertFalse(match.mayRead(.human("alice")))
        XCTAssertFalse(match.mayRead(.human("gpt")))
    }

    func testHumanAndModelKeysAreSeparateNamespaces() {
        XCTAssertNotEqual(OpponentID.human("gpt").key, OpponentID.model("gpt").key)
        XCTAssertEqual(OpponentID.human("Alice B!").key, "human-alice-b")
    }

    func testPvPContextCannotReadExistingHumanDossier() throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let alice = OpponentID.human("alice")
        var dossier = OpponentDossier(opponent: alice)
        dossier.notes = [note("secret", .tendency, statement: "SECRET alice castles late")]
        try store.save(dossier, persona: "kasia", in: singlePlayer(alice))

        let file = root.appendingPathComponent("personas/kasia/opponents/human-alice.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // Readable in single player.
        XCTAssertEqual(store.dossier(alice, persona: "kasia", in: singlePlayer(alice))?.notes.first?.id, "secret")
        // Not readable from any PvP context, whatever the model opponent.
        XCTAssertNil(store.dossier(alice, persona: "kasia", in: pvp(.model("gpt"))))
        XCTAssertNil(store.dossier(alice, persona: "kasia", in: pvp(.model("alice"))))
        // A single-player context against someone else cannot read it either.
        XCTAssertNil(store.dossier(alice, persona: "kasia", in: singlePlayer(.human("bob"))))
    }

    func testSaveHumanDossierInPvPThrowsAndWritesNothing() throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var dossier = OpponentDossier(opponent: .human("alice"))
        dossier.notes = [note("n")]
        XCTAssertThrowsError(try store.save(dossier, persona: "kasia", in: pvp(.model("gpt")))) {
            XCTAssertTrue($0 is MatchContext.PrivacyError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("personas/kasia/opponents/human-alice.json").path))
    }

    func testContextReadsOnlyItsOwnOpponentDossierFile() throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var other = OpponentDossier(opponent: .model("other"))
        other.notes = [note("o")]
        try store.save(other, persona: "kasia", in: pvp(.model("other")))
        XCTAssertNil(store.dossier(.model("other"), persona: "kasia", in: pvp(.model("gpt"))))
        XCTAssertEqual(store.dossier(.model("other"), persona: "kasia", in: pvp(.model("other")))?.notes.count, 1)
        // A fresh opponent yields an empty dossier, not nil.
        XCTAssertEqual(store.dossier(.model("gpt"), persona: "kasia", in: pvp(.model("gpt")))?.notes.count, 0)
    }
}
