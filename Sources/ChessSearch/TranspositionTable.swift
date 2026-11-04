import Foundation

/// Scores and best moves of searched positions by hash, so transpositions and later iterations are not searched
/// again. One entry per slot: a deeper result for the same position is kept, anything else is overwritten.
final class TranspositionTable: @unchecked Sendable {
    enum Bound: Int { case exact = 1, lower = 2, upper = 3 }

    struct Entry {
        var move: PackedMove
        var score: Int
        var depth: Int
        var bound: Bound
    }

    private let mask: Int
    private let keys: UnsafeMutablePointer<UInt64>
    /// move (16 bits), score (16, signed), depth (8), bound (2).
    private let data: UnsafeMutablePointer<UInt64>

    init(megabytes: Int) {
        var slots = 1
        while slots * 2 * 16 <= max(1, megabytes) << 20 { slots *= 2 }
        mask = slots - 1
        keys = .allocate(capacity: slots)
        data = .allocate(capacity: slots)
        clear()
    }

    deinit {
        keys.deallocate()
        data.deallocate()
    }

    func clear() {
        keys.initialize(repeating: 0, count: mask + 1)
        data.initialize(repeating: 0, count: mask + 1)
    }

    @inline(__always) func probe(_ key: UInt64) -> Entry? {
        let i = Int(truncatingIfNeeded: key) & mask
        guard keys[i] == key, data[i] != 0 else { return nil }
        let d = data[i]
        return Entry(
            move: PackedMove(raw: UInt16(truncatingIfNeeded: d)),
            score: Int(Int16(bitPattern: UInt16(truncatingIfNeeded: d >> 16))),
            depth: Int((d >> 32) & 0xFF),
            bound: Bound(rawValue: Int((d >> 40) & 3)) ?? .upper)
    }

    @inline(__always) func store(_ key: UInt64, move: PackedMove, score: Int, depth: Int, bound: Bound) {
        let i = Int(truncatingIfNeeded: key) & mask
        if keys[i] == key && data[i] != 0 && Int((data[i] >> 32) & 0xFF) > depth { return }
        keys[i] = key
        data[i] = UInt64(move.raw)
            | UInt64(UInt16(bitPattern: Int16(clamping: score))) << 16
            | UInt64(max(0, min(255, depth))) << 32
            | UInt64(bound.rawValue) << 40
    }
}
