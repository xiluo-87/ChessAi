import XCTest
import ChessCore
@testable import ChessAI

final class MemoryBudgetTests: XCTestCase {
    func testDropsDuplicateIdsKeepingFirst() {
        let out = MemoryBudget().trim([note("a", statement: "first"), note("a", statement: "second"), note("b")])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.first { $0.id == "a" }?.statement, "first")
    }

    func testClampsConfidence() {
        let out = MemoryBudget().trim([note("hi", confidence: 7), note("lo", confidence: -2)])
        XCTAssertEqual(out.first { $0.id == "hi" }?.confidence, 1)
        XCTAssertEqual(out.first { $0.id == "lo" }?.confidence, 0)
    }

    func testCapsEvidenceKeepingNewest() {
        let budget = MemoryBudget(evidencePerNote: 3)
        let out = budget.trim([note("a", evidence: ["g1", "g2", "g3", "g4", "g5"])])
        XCTAssertEqual(out[0].evidence, ["g3", "g4", "g5"])
    }

    func testKeepsMostConfidentWithinMaxNotes() {
        let budget = MemoryBudget(maxNotes: 3, maxTokens: 100_000)
        let notes = (0..<10).map { note("n\($0)", confidence: Double($0) / 10) }
        let out = budget.trim(notes)
        XCTAssertEqual(out.map(\.id), ["n9", "n8", "n7"])
    }

    func testRenderedSizeFitsTokenBudget() {
        let budget = MemoryBudget(maxNotes: 50, maxTokens: 120)
        let notes = (0..<20).map { note("n\($0)", statement: String(repeating: "x", count: 80), confidence: Double($0) / 20) }
        let out = budget.trim(notes)
        XCTAssertGreaterThan(out.count, 1)
        XCTAssertLessThan(out.count, 20)
        XCTAssertLessThanOrEqual(MemoryBudget.tokens(NoteRenderer.render(out)), 120)
        // The survivors are the most confident ones.
        XCTAssertEqual(out.map(\.id), (0..<out.count).map { "n\(19 - $0)" })
    }

    func testSingleOversizedNoteIsKept() {
        let budget = MemoryBudget(maxNotes: 5, maxTokens: 5)
        XCTAssertEqual(budget.trim([note("a", statement: String(repeating: "y", count: 400))]).count, 1)
    }

    func testStoreSaveTrimsPersona() throws {
        let (store, root) = tempStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var persona = MemoryStore.defaultPersona
        persona.notes = (0..<40).map { note("n\($0)", confidence: 0.5) }
        try store.save(persona)
        XCTAssertEqual(store.persona("kasia")?.notes.count, MemoryBudget.persona.maxNotes)
    }

    func testRepertoireFiltersAndSorts() {
        var persona = MemoryStore.defaultPersona
        persona.notes = [
            note("a", .opening, confidence: 0.4, line: ["d4"], side: .white),
            note("b", .opening, confidence: 0.9, line: ["e4"], side: .white),
            note("c", .opening, confidence: 0.9, line: ["e5"], side: .black),
            note("d", .opening, confidence: 0.9, line: [], side: .white),
            note("e", .strategy, confidence: 0.9, line: ["c4"], side: .white),
        ]
        XCTAssertEqual(persona.repertoire(for: .white).map(\.id), ["b", "a"])
    }
}
