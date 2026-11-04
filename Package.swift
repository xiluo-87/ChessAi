// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessAi",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ChessAi", targets: ["ChessApp"]),
        .executable(name: "chessai-cli", targets: ["ChessCLI"]),
    ],
    targets: [
        // Rules, move generation, SAN, FEN and PGN, and the engine protocol with its result types. No dependencies.
        .target(name: "ChessCore"),
        // Stockfish over UCI.
        .target(name: "ChessEngine", dependencies: ["ChessCore"]),
        // An in-process engine (alpha-beta search), for where Stockfish cannot run. Depends on ChessCore only.
        .target(name: "ChessSearch", dependencies: ["ChessCore"]),
        // Model adapters, persona memory, move picking and post-game analysis.
        .target(name: "ChessAI", dependencies: ["ChessCore", "ChessEngine"]),
        .executableTarget(name: "ChessApp", dependencies: ["ChessCore", "ChessEngine", "ChessAI"]),
        // Headless runs: self-play against a weakened engine, for live smoke tests and later AvA.
        .executableTarget(name: "ChessCLI", dependencies: ["ChessCore", "ChessEngine", "ChessAI"]),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"]),
        .testTarget(name: "ChessEngineTests", dependencies: ["ChessCore", "ChessEngine"]),
        .testTarget(name: "ChessAITests", dependencies: ["ChessAI"]),
        // ChessEngine only for the optional match against Stockfish.
        .testTarget(name: "ChessSearchTests", dependencies: ["ChessCore", "ChessSearch", "ChessEngine"]),
    ],
    swiftLanguageModes: [.v5]
)
