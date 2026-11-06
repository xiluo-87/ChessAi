# ChessAi

A native macOS chess app where you play **JSON Bourne**, an LLM chess persona that learns from every game.

A chess engine finds the sound moves: Stockfish, or `ChessSearch`, our own custom engine, which runs inside the app. A
language model picks among them by style, plan and what it has learned about you. After each game the persona reviews it with
the engine, then rewrites a small, bounded set of notes on its own play and
on its opponent. Every note records why it was noted. The same persona can play you locally, take on other bots and
people on Lichess, or face plain Stockfish at equal strength.

- **Learns you:** it tracks your openings, habits and costliest mistakes, and plays against them.
- **Develops a style:** favourite openings become its own book; preferences and weaknesses carry confidence and evidence.
- **Cheap to run:** the strong model is asked only when a choice matters; everything else is free and local.
- **Its own engine:** `ChessSearch` runs inside the app and can replace Stockfish with one setting.
- **Your model, your prompt:** runs on the CLIs you already use (`claude`, `codex`, `opencode`), with a model picker.

## Requirements

- macOS 14 or later, with Swift 6 (Xcode 16 or later, or the matching command line tools)
- [Stockfish](https://stockfishchess.org): `brew install stockfish`. It is the default engine. With `ChessSearch`
  selected, you only need it for Stockfish matches.
- At least one model CLI installed and signed in:
  - [Claude Code](https://claude.com/claude-code) (`claude`), the default; on a plan login it costs no API spend
  - [Codex](https://github.com/openai/codex) (`codex`)
  - [OpenCode](https://opencode.ai) (`opencode`), for any provider it serves, local models included

## Quick start

```bash
git clone https://github.com/xiluo-87/ChessAi.git
cd ChessAi
swift run -c release ChessAi
```

To get a regular app you can open from Finder, build `dist/ChessAi.app`. Add `--install` to copy it to `/Applications`:

```bash
scripts/make-app.sh --install
```

It is signed for this Mac only. macOS may ask once for Keychain access to your Lichess token, and
again after a rebuild. Settings and data are shared with `swift run`.

Start from the toolbar's **New Game** menu (⌘N as White, ⇧⌘N as Black), then drag or click your pieces. Moves are
listed as you play. When the game ends, the persona's review and summary appear under **Game → Review**, and its
updated notes in **Memory**. Settings that are set once (models, strength, Lichess account) are in **Settings** (⌘,).

## Modes

| Mode | Where | What happens afterwards |
|---|---|---|
| **You vs JSON Bourne** | Game tab | Reviewed; updates its own notes and its notes on you; counts in "vs you" |
| **Lichess bot** | Lichess tab | Reviewed; updates its own notes and a file per Lichess opponent; counts in "Lichess" |
| **JSON Bourne vs Stockfish** | New Game → Watch vs Stockfish (⌥⌘N) | Watch only: reads its notes, writes nothing, not counted |

In single player you see only the moves. In Lichess games and Stockfish matches, the persona's reason for each of its
moves is shown in full.

## How a move is chosen

Cheapest source first:

1. **Forced:** the only legal move.
2. **Book:** the next move of one of the persona's own opening lines, learned from earlier games.
3. **Engine:** the engine's top lines (MultiPV). If only one is sound, the best clearly leads, or quiet opening moves
   are equal, it plays without asking a model.
4. **Thought:** otherwise the **strong** model picks one sound candidate, with a short reason and a running plan.

The persona's prompt stays identical for a whole game, so the provider can cache it. Model calls are capped per game
and spread out so the middlegame keeps some. If a call fails, it plays the engine's best move instead of stalling.

**Strength** is the candidate search depth (Settings → Engine): about 6–8 plays at club level, 14 is very strong. A wider
candidate margin gives the persona more room for style at some cost in strength.

### The engines

Choose the engine in **Settings → Engine**. It finds the persona's candidates and reviews its games. A change applies
from the next game; the Lichess bot picks it up when it next goes online.

| | Stockfish | `ChessSearch` |
|---|---|---|
| Runs as | A separate program you install | Part of the app |
| Licence | GPLv3, not shipped with this repo | MIT, written for this project |
| Time limit | None: searches to the Strength depth | 2 seconds per position, even if short of that depth |
| Threads | Two | One |
| Strength | Far stronger | Weaker, see below |

**What `ChessSearch` is:** alpha-beta search (PVS, iterative deepening, aspiration windows, quiescence, a transposition
table, null-move pruning, late-move reductions) with MultiPV and repetition detection from the game's moves. Its
evaluation is material plus piece-square tables, with no king safety, pawn structure or mobility yet, so its openings
can look aimless. No code or tables come from Stockfish or any other engine. It exists because an iOS version cannot
run Stockfish, and it can be trained: see [Development](#development).

**Strength:** rough figures from 20-game matches at 200 ms per move against Stockfish 16, on a Linux VM, about ±150 Elo:

| Opponent | Result | Elo difference |
|---|---|---|
| Stockfish Skill 0 | +18 =0 −2 | +382 |
| Stockfish Skill 5 | +7 =0 −13 | −108 |
| Stockfish full strength, depth 6 | +10 =5 −5 | +89 |

**Use a release build.** `ChessSearch` runs inside the app, so a debug build slows it badly: about 41,000 nodes per
second against 2.2 million in release on a MacBook Pro. `swift run -c release` and `scripts/make-app.sh` are both
release builds; plain `swift run` is not.

## What it learns

After each game:

1. **The engine reviews every move locally:** loss in centipawns, inaccuracies, mistakes and blunders, the better move,
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

**Settings → Models** picks a backend, model and reasoning effort for each tier:

| Tier | Default | Used for |
|---|---|---|
| Strong | Claude Opus, low effort | choosing among candidates during a game |
| Cheap | Claude Haiku | the two post-game calls |

OpenCode's model list is read live from `opencode models`; any other model id can be typed in. The Game panel shows
each game's calls, tokens and list price. A test game with Sonnet as the strong model used 8 strong and 2 cheap calls,
about $0.05 at list price, which is $0 on a Claude plan login. With the strong-model budget at 0, the persona plays
engine-only and free.

Claude Code and Codex run isolated: no project instructions, no user configuration, and no session history, with
Claude Code's tools and MCP servers off and Codex in a read-only sandbox. OpenCode gets no isolation flags and runs
with your own OpenCode configuration.

## Using your own CLI

The list of CLIs is fixed in the code, because each one needs an adapter for its flags and output. The rest is found
or chosen at runtime:

| What | How it is set |
|---|---|
| Supported CLIs | Fixed: `claude`, `codex`, `opencode` |
| Location of the binary | Found on `PATH`, then in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.bun/bin` and `~/.npm-global/bin` |
| OpenCode models | Read from `opencode models` |
| Claude and Codex models | A fixed list, plus any id you type in |

**Without changing code:** use OpenCode. Configure the provider or local model there, then pick OpenCode as the backend
in **Settings → Models**. For a Claude or Codex model missing from the list, type its id into the picker.

**Binary in another folder:** add the folder to your `PATH`, or to `extraFolders` in
[`CLIRunner.swift`](Sources/ChessAI/Models/CLIRunner.swift). An app started from Finder gets a minimal `PATH`, so
`extraFolders` is the reliable choice there.

**Adding a CLI** takes changes in three files in [`Sources/ChessAI/Models`](Sources/ChessAI/Models), plus a test:

| File | Change |
|---|---|
| `ModelBackend.swift` | Add a case to `BackendKind` (its raw value is saved in settings) and to `ModelBackends.make` |
| `CLIBackends.swift` | Add the adapter, a type conforming to `ModelBackend` |
| `ModelCatalog.swift` | Add it to `command`, `title` and `models(for:)`, and add its reasoning efforts to `efforts` |
| [`CLIBackendTests.swift`](Tests/ChessAITests/CLIBackendTests.swift) | Test its arguments and environment, as the other adapters do |

The compiler flags each `switch` you missed, but not `efforts`, which is a dictionary. The picker and the router read
`BackendKind.allCases`, so the new CLI appears in **Settings → Models** with no UI work.

An adapter gets a system prompt, a user prompt, a JSON schema and a timeout, and returns the answer as decoded JSON.
This one suits a CLI that reads its prompt on stdin and cannot enforce a schema:

```swift
public struct MyCLIBackend: ModelBackend {
    public init() {}

    public func run(_ request: ModelRequest, model: ModelSpec) async throws -> ModelReply {
        guard let binary = CLIRunner.locate("mycli") else { throw ModelError.notInstalled("mycli") }
        let message = """
            \(request.system)

            ---

            \(request.prompt)

            Answer with one JSON object only, matching this JSON schema:
            \(request.schemaJSON)
            """
        let out = try await CLIRunner.run(
            binary, ["--model", model.model], stdin: message,
            environment: CLIRunner.environment(dropping: { _ in false }),
            directory: FileManager.default.temporaryDirectory, timeout: request.timeout)
        guard let json = ModelBackends.firstJSONObject(in: out.stdout) else {
            throw ModelError.badOutput("mycli exited \(out.status) without a JSON answer: \(out.stderr.tail())")
        }
        return ModelReply(json: json, usage: ModelUsage(), seconds: out.seconds)
    }
}
```

Keep these in mind when you write one:

- **Stateless:** each call must stand alone, with no session or conversation carried over.
- **No tools:** turn off the CLI's tools, project instructions and user configuration if it has flags for that.
- **Login over API keys:** use `environment(dropping:)` to remove any variable that would override the login you want,
  as the Claude and Codex adapters do.
- **Usage:** fill in `ModelUsage` if the CLI reports tokens or cost. Otherwise the cost panel shows zeros for its calls.

## Playing on Lichess

The persona plays as a **BOT account** through the [Lichess Bot API](https://lichess.org/api#tag/Bot), in the same
combined way. Engine use is allowed because the account is marked as a bot.

1. Register a separate Lichess account. Do not play any game with it.
2. Create a [personal API token](https://lichess.org/account/oauth/token/create?scopes[]=bot:play&description=ChessAi)
   with only the `bot:play` scope, and paste it into **Settings → Lichess**. It is stored in your macOS Keychain.
3. **Upgrade to BOT** there. This is permanent.
4. Switch the **Lichess** panel to **Online**. The bot accepts challenges matching Settings → Lichess: rapid,
   classical and correspondence by default; rated or casual; bots and humans.
5. Challenge someone yourself from **Play**, or pick a bot from **Lobby**: the bots online now, highest rated first
   for your clock. **Challenge** sends at once, with the clock and rated choice above the list, and the row shows a
   spinner until the bot answers. Unanswered challenges are withdrawn after 10 seconds. Bots that have hit Lichess's
   100 bot games a day, or declined in the last hour, stay listed but greyed out.

With under 90 seconds on its clock the persona skips the model and plays the engine's top move. Dropped game streams
reconnect without losing the game. Only rated games change a rating; Lichess shows a placeholder until then.

## JSON Bourne vs Stockfish

Start it from **New Game → Watch vs Stockfish** (⌥⌘N); the depth and side are in Settings → Stockfish Match. A watch-only match at **equal strength**: Stockfish plays its best move at depth N; the persona gets Stockfish's
candidates at the same depth N and its model picks one. It answers one question: do the model's choices among
near-equal moves beat Stockfish's own top pick? Expect many draws.

## Data

Everything stays on your Mac:

| What | Where |
|---|---|
| Persona, notes, opponent files, games (JSON) | `~/Library/Application Support/ChessAi/` |
| Settings | the app's UserDefaults |
| Lichess token | macOS Keychain, service `ChessAi.lichess` |
| Training data: every finished game's quiet positions and result | `~/Library/Application Support/ChessAi/training/games.txt` |

**Settings → General → Reset** clears the persona's own notes. Saving training data can be turned off there too.

## Development

```bash
swift build
swift test          # about 140 tests: perft, both engines, training, memory, privacy, picker, CLI arguments, Lichess (stubbed)
```

The Stockfish, move picker and Lichess game tests need Stockfish and skip without it; `ChessSearch`'s tests do not.
No test calls a real model or lichess.org.

`ChessSearch`'s speed, and a match against Stockfish for a rough strength estimate, are opt-in tests (options in
`Tests/ChessSearchTests/StrengthTests.swift`):

```bash
CHESSAI_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter StrengthTests.testBenchmark
CHESSAI_MATCH=20 swift test -c release -Xswiftc -enable-testing --filter StrengthTests.testMatchAgainstStockfish
```

A headless game against a weakened Stockfish, with real model calls, for smoke tests:

```bash
swift run chessai-cli selfplay --plies 50 --strong sonnet --cheap haiku
```

Training `ChessSearch`'s evaluation (Texel tuning: fit its piece-square values to game results), then checking
that the tuned weights beat the ones they started from. Weights are kept in rounds, in
`Sources/ChessSearch/Resources/Weights/round-N.json`: round 0 is the standard hand-written values, and each later
round records the positions it was fitted to and how it played against the round before (`chessai-train rounds`).
`round:N` names a kept round wherever a weights file is accepted. One round, from the latest kept one (here 1):

```bash
swift run -c release chessai-train selfplay --games 5000 --depth 5 --weights round:1 --out selfplay.txt
# optional: the app's own games, saved after each one (see Data)
cp ~/Library/Application\ Support/ChessAi/training/games.txt app-games.txt
swift run -c release chessai-train pgn games.pgn --out pgn.txt          # optional: any PGN with results
swift run -c release chessai-train tune selfplay.txt pgn.txt app-games.txt --from round:1 --out round-2.json
swift run -c release chessai-train compare round-2.json --against round:1 --games 400 --depth 5 --record
```

Keep the new round by copying it to `Resources/Weights` with its round number. The engine plays round 0 unless told
otherwise: `SearchEngine(weights: try EvalWeights.bundled(round: 1))`, or `EvalWeights(contentsOf:)` for a file.

| Target | Contents |
|---|---|
| `ChessCore` | Rules, legal move generation, SAN, FEN, PGN (perft-tested); the `AnalysisEngine` protocol |
| `ChessEngine` | Stockfish over UCI, with serialized commands |
| `ChessSearch` | `SearchEngine`, our own in-process alpha-beta engine, chosen in Settings → Engine; also for where Stockfish cannot run (iOS) |
| `ChessAI` | Model CLI adapters, router and cost ledger, memory store, move picker, game review, memory updater, Lichess client and bot |
| `ChessApp` | The SwiftUI app |
| `ChessCLI` | Headless self-play |
| `ChessTrain` | `chessai-train`: self-play and PGN positions, evaluation tuning, matches between weights |

## License

[MIT](LICENSE) © 2026 Xi Luo

ChessAi is an independent project, not affiliated with Lichess, Stockfish, Anthropic, OpenAI or OpenCode.
