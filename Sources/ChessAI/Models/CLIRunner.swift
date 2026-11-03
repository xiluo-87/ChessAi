import Foundation

/// Runs one CLI process with its prompt on stdin, collects stdout and stderr, and stops it at its deadline.
enum CLIRunner {
    struct Output {
        var stdout: String
        var stderr: String
        var status: Int32
        var seconds: Double
    }

    /// Folders searched besides PATH: an app started from Finder gets a minimal PATH without the user's tools.
    private static let extraFolders = [
        "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "\(NSHomeDirectory())/.bun/bin", "\(NSHomeDirectory())/.npm-global/bin",
    ]

    static func locate(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init) + extraFolders
        return folders.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The parent environment without `dropped` names, plus `extra`; PATH gains the extra folders so the CLI finds
    /// its own helpers (node, git) when the app was started from Finder.
    static func environment(dropping dropped: (String) -> Bool, extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !dropped($0.key) }
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = ([path] + extraFolders).joined(separator: ":")
        return env.merging(extra) { _, new in new }
    }

    static func run(
        _ executable: String, _ arguments: [String], stdin: String, environment: [String: String],
        directory: URL? = nil, timeout: TimeInterval
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let collected = Collected()
        output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, error: false) }
        errors.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData, error: true) }

        let started = Date()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                // Whatever is still buffered after exit.
                collected.append(output.fileHandleForReading.readDataToEndOfFile(), error: false)
                collected.append(errors.fileHandleForReading.readDataToEndOfFile(), error: true)
                let (out, err) = collected.texts()
                once.run {
                    continuation.resume(returning: Output(
                        stdout: out, stderr: err, status: finished.terminationStatus,
                        seconds: Date().timeIntervalSince(started)))
                }
            }
            do {
                try process.run()
            } catch {
                once.run { continuation.resume(throwing: ModelError.failed("\(executable) did not start: \(error)")) }
                return
            }
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                once.run { continuation.resume(throwing: ModelError.timeout(timeout)) }
            }
        }
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        func append(_ data: Data, error: Bool) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            if error { err.append(data) } else { out.append(data) }
        }

        func texts() -> (String, String) {
            lock.lock(); defer { lock.unlock() }
            return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func run(_ body: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { body() }
        }
    }
}

extension String {
    /// The last `count` characters, for error messages.
    func tail(_ count: Int = 400) -> String {
        self.count <= count ? self : "…" + suffix(count)
    }
}
