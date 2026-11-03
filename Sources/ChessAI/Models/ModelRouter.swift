import Foundation

/// Which model a call needs. Only `strong` thinks about moves during a match; everything else is `cheap`.
public enum ModelTier: String, Codable, Sendable, CaseIterable {
    case strong
    case cheap
}

/// The model routing the app uses. Defaults favor the plan login: no API spend at all.
public struct ModelRouting: Codable, Sendable, Hashable {
    public var strong: ModelSpec
    public var cheap: ModelSpec
    /// Tried in order when the tier's model fails (not installed, usage limit, timeout).
    public var fallbacks: [ModelSpec]

    public init(strong: ModelSpec, cheap: ModelSpec, fallbacks: [ModelSpec] = []) {
        self.strong = strong
        self.cheap = cheap
        self.fallbacks = fallbacks
    }

    public static let `default` = ModelRouting(
        strong: ModelSpec(backend: .claudeCLI, model: "opus", effort: "low"),
        cheap: ModelSpec(backend: .claudeCLI, model: "haiku"),
        fallbacks: [ModelSpec(backend: .claudeCLI, model: "sonnet", effort: "low")])

    public func spec(for tier: ModelTier) -> ModelSpec { tier == .strong ? strong : cheap }
}

/// One finished call, for the cost panel.
public struct CallRecord: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var purpose: String
    public var tier: ModelTier
    public var model: String
    public var usage: ModelUsage
    public var seconds: Double
    public var date = Date()
}

/// Routes calls to the tier's model with fallbacks, and keeps the ledger of every call's usage.
public actor ModelRouter {
    public private(set) var routing: ModelRouting
    public private(set) var ledger: [CallRecord] = []
    private let backends: [BackendKind: ModelBackend]

    public init(routing: ModelRouting, backends: [BackendKind: ModelBackend]? = nil) {
        self.routing = routing
        self.backends = backends ?? Dictionary(uniqueKeysWithValues: BackendKind.allCases.map { ($0, ModelBackends.make($0)) })
    }

    public func update(_ routing: ModelRouting) { self.routing = routing }

    public func call(_ request: ModelRequest, tier: ModelTier, purpose: String) async throws -> ModelReply {
        let chain = [routing.spec(for: tier)] + routing.fallbacks.filter { $0 != routing.spec(for: tier) }
        var lastError: Error = ModelError.failed("no model configured")
        for spec in chain {
            guard let backend = backends[spec.backend] else { continue }
            do {
                let reply = try await backend.run(request, model: spec)
                ledger.append(CallRecord(purpose: purpose, tier: tier, model: spec.label, usage: reply.usage, seconds: reply.seconds))
                return reply
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func totals(since date: Date = .distantPast) -> ModelUsage {
        ledger.filter { $0.date >= date }.reduce(ModelUsage()) { $0 + $1.usage }
    }

    public func records(since date: Date = .distantPast) -> [CallRecord] {
        ledger.filter { $0.date >= date }
    }
}
