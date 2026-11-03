import Foundation

/// Thread-safe line buffer fed from a pipe's readabilityHandler and consumed
/// asynchronously with a timeout. Never blocks a thread while waiting.
final class LineReader: @unchecked Sendable {
    enum Result: Sendable {
        case line(String)
        case timeout
        case eof
    }

    private let lock = NSLock()
    private var partial = Data()
    private var queue: [String] = []
    private var closed = false
    private var waiter: (id: Int, cont: CheckedContinuation<Result, Never>)?
    private var nextID = 0

    func feed(_ data: Data) {
        var deliver: [(CheckedContinuation<Result, Never>, Result)] = []
        lock.lock()
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            let lineData = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            var s = String(decoding: lineData, as: UTF8.self)
            if s.hasSuffix("\r") { s.removeLast() }
            if let w = waiter {
                waiter = nil
                deliver.append((w.cont, .line(s)))
            } else {
                queue.append(s)
            }
        }
        lock.unlock()
        for (c, r) in deliver { c.resume(returning: r) }
    }

    func finish() {
        lock.lock()
        closed = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.cont.resume(returning: .eof)
    }

    func drain() {
        lock.lock()
        queue.removeAll()
        lock.unlock()
    }

    func next(timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            lock.lock()
            if !queue.isEmpty {
                let l = queue.removeFirst()
                lock.unlock()
                cont.resume(returning: .line(l))
                return
            }
            if closed {
                lock.unlock()
                cont.resume(returning: .eof)
                return
            }
            nextID += 1
            let id = nextID
            // One reader at a time (the engine serializes its commands). Should a second waiter arrive anyway, the
            // first gets a timeout instead of being dropped unresumed.
            let displaced = waiter
            waiter = (id, cont)
            lock.unlock()
            displaced?.cont.resume(returning: .timeout)
            // Strong capture: the continuation must be resumed even if the engine is released meanwhile.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                self.fireTimeout(id)
            }
        }
    }

    private func fireTimeout(_ id: Int) {
        lock.lock()
        guard let w = waiter, w.id == id else { lock.unlock(); return }
        waiter = nil
        lock.unlock()
        w.cont.resume(returning: .timeout)
    }
}
