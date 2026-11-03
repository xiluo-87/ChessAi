import Foundation

public actor StockfishEngine {
    private let path: String
    private var process: Process?
    private var stdinHandle: FileHandle?
    private let reader = LineReader()
    private var started = false
    private var currentMultiPV = 1

    public static func locate() -> String? {
        let fm = FileManager.default
        for p in ["/opt/homebrew/bin/stockfish", "/usr/local/bin/stockfish"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathVar.split(separator: ":") {
            let p = String(dir) + "/stockfish"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public init(path: String? = nil) throws {
        guard let resolved = path ?? StockfishEngine.locate(),
              FileManager.default.isExecutableFile(atPath: resolved) else {
            throw EngineError.notFound
        }
        self.path = resolved
    }

    deinit {
        if let p = process, p.isRunning { p.terminate() }
    }

    // MARK: - Serialization

    /// The actor is reentrant: while one command awaits the engine's output, another call may enter. Stockfish's
    /// output is one stream, so each command holds this lock until its answer is read; later calls queue in order.
    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { queued.append($0) }  // busy stays true: release hands the lock over
        } else {
            busy = true
        }
    }

    private func release() {
        if queued.isEmpty { busy = false } else { queued.removeFirst().resume() }
    }

    // MARK: - Lifecycle

    public func start(threads: Int = 2, hashMB: Int = 64) async throws {
        await acquire()
        defer { release() }
        try await startEngine(threads: threads, hashMB: hashMB)
    }

    private func startEngine(threads: Int, hashMB: Int) async throws {
        if started { return }
        signal(SIGPIPE, SIG_IGN)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        let reader = self.reader
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                reader.finish()
            } else {
                reader.feed(data)
            }
        }
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            throw EngineError.launchFailed("\(error)")
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
        started = true
        do {
            try send("uci")
            try await wait(for: "uciok", timeout: 10)
            try send("setoption name Threads value \(max(1, threads))")
            try send("setoption name Hash value \(max(1, hashMB))")
            try await sync()
        } catch {
            shutdown()
            throw error
        }
    }

    public func setOption(name: String, value: String) async throws {
        await acquire()
        defer { release() }
        try await applyOption(name: name, value: value)
    }

    private func applyOption(name: String, value: String) async throws {
        try send("setoption name \(name) value \(value)")
        if name.lowercased() == "multipv", let v = Int(value) { currentMultiPV = v }
        try await sync()
    }

    public func newGame() async throws {
        await acquire()
        defer { release() }
        try send("ucinewgame")
        try await sync()
    }

    public func shutdown() {
        guard let p = process else { return }
        if p.isRunning {
            try? stdinHandle?.write(contentsOf: Data("quit\n".utf8))
            p.terminate()
        }
        try? stdinHandle?.close()
        process = nil
        stdinHandle = nil
        started = false
        reader.finish()
    }

    // MARK: - Search

    public func analyse(fen: String, multiPV: Int, limits: EngineLimits) async throws -> [EngineLine] {
        await acquire()
        defer { release() }
        return try await analyseNow(fen: fen, multiPV: multiPV, limits: limits)
    }

    private func analyseNow(fen: String, multiPV: Int, limits: EngineLimits) async throws -> [EngineLine] {
        let n = max(1, multiPV)
        if n != currentMultiPV {
            try send("setoption name MultiPV value \(n)")
            currentMultiPV = n
            try await sync()
        }
        let (lines, _) = try await search(fen: fen, limits: limits)
        return Array(lines.prefix(n))
    }

    public func bestMove(fen: String, limits: EngineLimits) async throws -> String? {
        await acquire()
        defer { release() }
        return try await bestMoveNow(fen: fen, limits: limits)
    }

    private func bestMoveNow(fen: String, limits: EngineLimits) async throws -> String? {
        if currentMultiPV != 1 {
            try send("setoption name MultiPV value 1")
            currentMultiPV = 1
            try await sync()
        }
        let (_, best) = try await search(fen: fen, limits: limits)
        return best
    }

    private func search(fen: String, limits: EngineLimits) async throws -> ([EngineLine], String?) {
        guard started, process?.isRunning == true else { throw EngineError.terminated }
        reader.drain()
        try send("position fen \(fen)")
        var go = "go"
        var timeout: TimeInterval = 120
        if let d = limits.depth { go += " depth \(d)" }
        if let mt = limits.movetimeMs {
            go += " movetime \(mt)"
            timeout = limits.depth == nil ? Double(mt) / 1000 + 15 : 120
        }
        if limits.depth == nil && limits.movetimeMs == nil {
            go += " movetime 1000"
            timeout = 16
        }
        try send(go)

        var byPV: [Int: EngineLine] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { await abortSearch(); throw EngineError.noResponse("search timed out") }
            switch await reader.next(timeout: remaining) {
            case .eof:
                shutdown()
                throw EngineError.terminated
            case .timeout:
                await abortSearch()
                throw EngineError.noResponse("search timed out")
            case .line(let line):
                if line.hasPrefix("bestmove") {
                    let parts = line.split(separator: " ")
                    var best: String? = parts.count > 1 ? String(parts[1]) : nil
                    if best == "(none)" || best == "0000" { best = nil }
                    let lines = byPV.keys.sorted().compactMap { byPV[$0] }
                    return (lines, best)
                }
                if let (k, l) = Self.parseInfo(line) {
                    byPV[k] = l
                }
            }
        }
    }

    private func abortSearch() async {
        try? send("stop")
        let end = Date().addingTimeInterval(3)
        while end.timeIntervalSinceNow > 0 {
            switch await reader.next(timeout: end.timeIntervalSinceNow) {
            case .line(let l) where l.hasPrefix("bestmove"): return
            case .line: continue
            default: return
            }
        }
    }

    static func parseInfo(_ line: String) -> (Int, EngineLine)? {
        guard line.hasPrefix("info ") else { return nil }
        let t = line.split(separator: " ").map(String.init)
        var depth: Int?
        var multipv = 1
        var cp: Int?
        var mate: Int?
        var pv: [String] = []
        var bound = false
        var i = 1
        while i < t.count {
            switch t[i] {
            case "depth":
                if i + 1 < t.count { depth = Int(t[i + 1]) }
                i += 2
            case "multipv":
                if i + 1 < t.count { multipv = Int(t[i + 1]) ?? 1 }
                i += 2
            case "score":
                if i + 2 < t.count {
                    if t[i + 1] == "cp" { cp = Int(t[i + 2]) }
                    else if t[i + 1] == "mate" { mate = Int(t[i + 2]) }
                }
                i += 3
            case "lowerbound", "upperbound":
                bound = true
                i += 1
            case "pv":
                pv = Array(t[(i + 1)...])
                i = t.count
            default:
                i += 1
            }
        }
        guard !bound, let d = depth, !pv.isEmpty, cp != nil || mate != nil else { return nil }
        return (multipv, EngineLine(move: pv[0], score: EngineScore(centipawns: cp, mate: mate), pv: pv, depth: d))
    }

    // MARK: - IO helpers

    private func send(_ command: String) throws {
        guard let h = stdinHandle, process?.isRunning == true else { throw EngineError.terminated }
        do {
            try h.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            throw EngineError.terminated
        }
    }

    private func wait(for prefix: String, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw EngineError.noResponse("timeout waiting for \(prefix)") }
            switch await reader.next(timeout: remaining) {
            case .eof:
                shutdown()
                throw EngineError.terminated
            case .timeout:
                throw EngineError.noResponse("timeout waiting for \(prefix)")
            case .line(let l):
                if l.hasPrefix(prefix) { return }
            }
        }
    }

    private func sync() async throws {
        try send("isready")
        try await wait(for: "readyok", timeout: 10)
    }
}
