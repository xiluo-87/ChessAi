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
        // Rules, move generation, SAN, FEN and PGN. No dependencies.
        .target(name: "ChessCore"),
        // Stockfish over UCI.
        .target(name: "ChessEngine"),
        // Model adapters, persona memory, move picking and post-game analysis.
        .target(name: "ChessAI", dependencies: ["ChessCore", "ChessEngine"]),
        .executableTarget(name: "ChessApp", dependencies: ["ChessCore", "ChessEngine", "ChessAI"]),
        // Headless runs: self-play against a weakened engine, for live smoke tests and later AvA.
        .executableTarget(name: "ChessCLI", dependencies: ["ChessCore", "ChessEngine", "ChessAI"]),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"]),
        .testTarget(name: "ChessEngineTests", dependencies: ["ChessEngine"]),
        .testTarget(name: "ChessAITests", dependencies: ["ChessAI"]),
    ],
    swiftLanguageModes: [.v5]
)
