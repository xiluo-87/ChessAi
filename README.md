# ChessAi

A native macOS chess app where you play an LLM chess persona that learns: it keeps bounded notes on its own play
(favourite openings, strategic preferences, weaknesses, each with the evidence for it) and a scouting file on you,
and rewrites both after every game.

## Run

```bash
brew install stockfish
swift run ChessAi
```

The app calls `claude` (default), `codex` or `opencode` directly, as installed and logged in. Pick the models in the
**Models** tab or in Settings (⌘,).

Headless game against a weakened engine, with real model calls, for smoke tests:

```bash
swift run chessai-cli selfplay --plies 50 --strong sonnet --cheap haiku
```

## How a move is chosen (cheapest source first)

1. **Forced**: the only legal move.
2. **Book**: the next move of one of the persona's own repertoire lines, learned from earlier games.
3. **Engine**: Stockfish's candidates; if only one is sound, or the best leads clearly, or quiet opening moves are
   equal, it is played without asking a model.
4. **Thought**: otherwise the **strong** model picks one sound candidate by style, plan and its notes on you. The
   system prompt stays identical for the whole game, so it is prompt-cached. Calls are capped per game and paced, so
   the middlegame still gets some.

After the game, Stockfish reviews every move locally (free), and the **cheap** model makes two calls: it rewrites the
persona's notes with a game summary, and it rewrites the notes on the opponent.

## Memory

Stored in `~/Library/Application Support/ChessAi/`: `personas/<id>/profile.json`,
`personas/<id>/opponents/<opponent>.json` and `games/<id>.json`.

- Notes are rewritten, not appended: at most 16 notes / ~1.4k tokens for the persona, and 12 / ~1k for an opponent.
  Each note keeps a rationale, a confidence, and up to five evidence games.
- A **PvP** match (persona vs another model) can never read or write a human's dossier. `MatchContext` enforces this,
  and tests cover it.

## Layout

| Target | Contents |
|---|---|
| `ChessCore` | Rules, move generation, SAN, FEN, PGN (perft-tested) |
| `ChessEngine` | Stockfish over UCI |
| `ChessAI` | CLI model adapters, router and ledger, memory, move picker, review, memory updater |
| `ChessApp` | SwiftUI app |
| `ChessCLI` | Headless self-play |
