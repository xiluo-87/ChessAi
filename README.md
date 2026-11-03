# ChessAi

A native macOS chess app where you play **JSON Bourne**, an LLM chess persona that learns from every game.

Stockfish finds the sound moves; a language model picks among them by style, plan and what it has learned about you.
After each game the persona reviews it with Stockfish, then rewrites a small, bounded set of notes on its own play and
on its opponent. Every note records why it was noted. The same persona can play you locally, take on other bots and
people on Lichess, or face plain Stockfish at equal strength.

- **Learns you:** it tracks your openings, habits and costliest mistakes, and plays against them.
- **Develops a style:** favourite openings become its own book; preferences and weaknesses carry confidence and evidence.
- **Cheap to run:** the strong model is asked only when a choice matters; everything else is free and local.
- **Your model, your prompt:** runs on the CLIs you already use (`claude`, `codex`, `opencode`), with a model picker.

## Requirements

- macOS 14 or later, with Swift 6 (Xcode 16 or later, or the matching command line tools)
- [Stockfish](https://stockfishchess.org): `brew install stockfish`
- At least one model CLI installed and signed in:
  - [Claude Code](https://claude.com/claude-code) (`claude`), the default; on a plan login it costs no API spend
  - [Codex](https://github.com/openai/codex) (`codex`)
  - [OpenCode](https://opencode.ai) (`opencode`), for any provider it serves, local models included

## Quick start

```bash
git clone https://github.com/xiluo-87/ChessAi.git
cd ChessAi
swift run ChessAi
```

Choose **New as White** or **New as Black** (⌘N / ⇧⌘N), then drag or click your pieces. Moves are listed as you play.
When the game ends, the persona's review and summary appear in the **Game** tab, and its updated notes in **Memory**.

## Modes

| Mode | Where | What happens afterwards |
|---|---|---|
| **You vs JSON Bourne** | Game tab | Reviewed; updates its own notes and its notes on you; counts in "vs you" |
| **Lichess bot** | Lichess tab | Reviewed; updates its own notes and a file per Lichess opponent; counts in "Lichess" |
| **JSON Bourne vs Stockfish** | Game tab | Watch only: reads its notes, writes nothing, not counted |

In single player you see only the moves. In Lichess games and Stockfish matches, the persona's reason for each of its
moves is shown in full.

## How a move is chosen

Cheapest source first:

1. **Forced:** the only legal move.
2. **Book:** the next move of one of the persona's own opening lines, learned from earlier games.
3. **Engine:** Stockfish's top lines (MultiPV). If only one is sound, the best clearly leads, or quiet opening moves
   are equal, it plays without asking a model.
4. **Thought:** otherwise the **strong** model picks one sound candidate, with a short reason and a running plan.

The persona's prompt stays identical for a whole game, so the provider can cache it. Model calls are capped per game
and spread out so the middlegame keeps some. If a call fails, it plays the engine's best move instead of stalling.

**Strength** is the candidate search depth (Models tab): about 6–8 plays at club level, 14 is very strong. A wider
candidate margin gives the persona more room for style at some cost in strength.

## What it learns

After each game:

1. **Stockfish reviews every move locally:** loss in centipawns, inaccuracies, mistakes and blunders, the better move,
   and per-side statistics such as accuracy by phase, castling timing and early queen moves. This is free.
2. **The cheap model makes two calls:**
   - It rewrites the persona's own notes (openings, strategy, principles, weaknesses) and writes a short summary.
   - It rewrites its notes on the opponent (openings, tendencies, weaknesses, exploits).

Notes are **rewritten, never appended**, and kept within a budget:

| File | Notes | Approx. tokens |
|---|---|---|
| Persona's own notes | 16 | 1,400 |
| Notes on one opponent | 12 | 1,000 |

Every note carries a **rationale** (the evidence that made it worth noting), a confidence that rises or falls with
later games, and up to five evidence games. Opening notes keep the line, which becomes the persona's book. Games
shorter than 6 plies are saved and counted but not reviewed.

**Privacy:** your notes are loaded only in your own games. A Lichess game or a match against another model can never
read or write them. `MatchContext` enforces this, and tests check it down to the prompt text.

## Models and cost

The **Models** tab picks a backend, model and reasoning effort for each tier:

| Tier | Default | Used for |
|---|---|---|
| Strong | Claude Opus, low effort | choosing among candidates during a game |
| Cheap | Claude Haiku | the two post-game calls |

OpenCode's model list is read live from `opencode models`; any other model id can be typed in. The Game tab shows
each game's calls, tokens and list price. A test game with Sonnet as the strong model used 8 strong and 2 cheap calls,
about $0.05 at list price, which is $0 on a Claude plan login. With the strong-model budget at 0, the persona plays
engine-only and free.

The CLIs run isolated: no tools, no project instructions, no user configuration or MCP servers, and no session
history. Flags and environment handling follow each CLI's non-interactive mode.

## Playing on Lichess

The persona plays as a **BOT account** through the [Lichess Bot API](https://lichess.org/api#tag/Bot), in the same
combined way. Engine use is allowed because the account is marked as a bot.

1. Register a separate Lichess account. Do not play any game with it.
2. Create a [personal API token](https://lichess.org/account/oauth/token/create?scopes[]=bot:play&description=ChessAi)
   with only the `bot:play` scope, and paste it into **Lichess → Bot**. It is stored in your macOS Keychain.
3. **Upgrade to BOT** from the same tab. This is permanent.
4. **Go online.** The bot accepts challenges matching your settings: rapid, classical and correspondence by default;
   rated or casual; bots and humans.
5. Challenge someone yourself from **Play**, or pick a bot from **Lobby**, which lists the bots online now with their
   rating for your clock. Bots that have hit Lichess's 100 bot games a day, or recently declined, are hidden for a while.

With under 90 seconds on its clock the persona skips the model and plays Stockfish's top move. Dropped game streams
reconnect without losing the game. Only rated games change a rating; Lichess shows a placeholder until then.

## JSON Bourne vs Stockfish

A watch-only match at **equal strength**: Stockfish plays its best move at depth N; the persona gets Stockfish's
candidates at the same depth N and its model picks one. It answers one question: do the model's choices among
near-equal moves beat Stockfish's own top pick? Expect many draws.

## Data

Everything stays on your Mac:

| What | Where |
|---|---|
| Persona, notes, opponent files, games (JSON) | `~/Library/Application Support/ChessAi/` |
| Settings | the app's UserDefaults |
| Lichess token | macOS Keychain, service `ChessAi.lichess` |

**Memory → Reset persona memory** clears the persona's own notes.

## Development

```bash
swift build
swift test          # about 100 tests: perft, engine, memory, privacy, picker, CLI arguments, Lichess (stubbed)
```

The engine and Lichess game tests need Stockfish and skip without it. No test calls a real model or lichess.org.

A headless game against a weakened Stockfish, with real model calls, for smoke tests:

```bash
swift run chessai-cli selfplay --plies 50 --strong sonnet --cheap haiku
```

| Target | Contents |
|---|---|
| `ChessCore` | Rules, legal move generation, SAN, FEN, PGN (perft-tested) |
| `ChessEngine` | Stockfish over UCI, with serialized commands |
| `ChessAI` | Model CLI adapters, router and cost ledger, memory store, move picker, game review, memory updater, Lichess client and bot |
| `ChessApp` | The SwiftUI app |
| `ChessCLI` | Headless self-play |

## License

[MIT](LICENSE) © 2026 Xi Luo

ChessAi is an independent project, not affiliated with Lichess, Stockfish, Anthropic, OpenAI or OpenCode.
