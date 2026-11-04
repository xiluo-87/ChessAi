import SwiftUI
import AppKit
import ChessAI

enum SettingsTab: String {
    case general, models, lichess, match
}

/// The app's Settings window (⌘,): everything set once and rarely changed, out of the main window.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    /// Panels open Settings on the tab they need by setting this first.
    @AppStorage("settings.tab") private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)
            LichessSettings(lichess: model.lichess)
                .tabItem { Label("Lichess", systemImage: "globe") }
                .tag(SettingsTab.lichess)
            MatchSettings()
                .tabItem { Label("Stockfish Match", systemImage: "flag.2.crossed") }
                .tag(SettingsTab.match)
        }
        .frame(width: 540, height: 500)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false
    @AppStorage(TrainingDefaults.saveGamesKey) private var saveTraining = true
    @State private var savedPositions: Int?

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $model.settings.playerName)
            } footer: {
                Text("How \(model.persona.name) knows you in single-player games.")
            }
            Section {
                LabeledContent("Strength") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(model.settings.play.engineDepth) },
                            set: { model.settings.play.engineDepth = Int($0) }), in: 4...20, step: 1)
                        Text("depth \(model.settings.play.engineDepth)")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                Stepper("Strong-model calls per game: \(model.settings.play.maxModelCalls)",
                        value: $model.settings.play.maxModelCalls, in: 0...80, step: 5)
                Stepper("Candidate margin: \(model.settings.play.marginCp) cp",
                        value: $model.settings.play.marginCp, in: 10...200, step: 10)
            } header: {
                Text("\(model.persona.name)'s play")
            } footer: {
                Text("A wider margin gives more freedom of style and costs strength; 0 calls plays engine-only, free. Changes apply from the next game.")
            }
            Section("Memory") {
                LabeledContent("\(model.persona.name)'s notes on its own play") {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                }
            }
            Section {
                Toggle("Save finished games for training", isOn: $saveTraining)
                LabeledContent("Saved positions") {
                    HStack {
                        Text(savedPositions.map { $0.formatted() } ?? "–").monospacedDigit()
                        InfoButton {
                            Text("Each finished game, against you, on Lichess or against Stockfish, adds its quiet positions and its result. To train a new round of the engine's weights from them:")
                            Text("chessai-train tune \(model.trainingFile.path) --from round:N --out round-N+1.json")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.trainingFile])
                        }
                        .disabled(savedPositions == nil)
                    }
                }
            } header: {
                Text("Training data")
            }
        }
        .formStyle(.grouped)
        .task { savedPositions = await Self.lineCount(model.trainingFile) }
        .confirmationDialog("Erase all of \(model.persona.name)'s notes on its own play?", isPresented: $confirmReset) {
            Button("Erase", role: .destructive) { model.resetPersonaMemory() }
        }
    }
}

extension GeneralSettings {
    /// Positions in the training file (one per line); nil when there is no file yet.
    static func lineCount(_ url: URL) async -> Int? {
        await Task.detached(priority: .utility) { () -> Int? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return data.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        }.value
    }
}

// MARK: Models

private struct ModelSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            TierSection(
                title: "Strong model: thinks during the match",
                hint: "Asked only when several sound moves remain. Prompt-cached per game.",
                spec: $model.settings.routing.strong)
            TierSection(
                title: "Cheap model: post-game notes and summaries",
                hint: "Two calls per game: the persona's notes, and its notes on you.",
                spec: $model.settings.routing.cheap)
        }
        .formStyle(.grouped)
    }
}

// MARK: Lichess

private struct LichessSettings: View {
    @ObservedObject var lichess: LichessController
    @State private var token = ""
    @State private var confirmUpgrade = false

    private static let tokenURL = URL(string: "https://lichess.org/account/oauth/token/create?scopes[]=bot:play&description=ChessAi")!

    var body: some View {
        Form {
            Section {
                account
            } header: {
                Text("Account")
            } footer: {
                if !lichess.hasToken {
                    Text("Use a separate Lichess account for the bot. The token needs the bot:play scope and is kept in your Keychain.")
                } else if lichess.account?.isBot == false {
                    Text("Bots play through the Bot API, which needs a BOT account. The upgrade is permanent and only works on an account that has never played a game.")
                }
            }
            if lichess.account?.isBot == true {
                Section {
                    LabeledContent("Speeds") {
                        HStack {
                            ForEach(["blitz", "rapid", "classical", "correspondence"], id: \.self) { speed in
                                Toggle(speed, isOn: Binding(
                                    get: { lichess.settings.speeds.contains(speed) },
                                    set: { on in
                                        if on { lichess.settings.speeds.insert(speed) } else { lichess.settings.speeds.remove(speed) }
                                    }))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                    LabeledContent("Games") {
                        HStack {
                            Toggle("rated", isOn: $lichess.settings.acceptRated).toggleStyle(.checkbox)
                            Toggle("casual", isOn: $lichess.settings.acceptCasual).toggleStyle(.checkbox)
                        }
                    }
                    LabeledContent("Opponents") {
                        HStack {
                            Toggle("bots", isOn: $lichess.settings.acceptBots).toggleStyle(.checkbox)
                            Toggle("humans", isOn: $lichess.settings.acceptHumans).toggleStyle(.checkbox)
                        }
                    }
                } header: {
                    Text("Accepts challenges")
                } footer: {
                    Text("With under 90 s on its clock the bot skips the model and plays the engine's top candidate, so blitz is mostly engine moves. Changes apply when the bot next goes online.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var account: some View {
        if !lichess.hasToken {
            Link("Create a token on lichess.org", destination: Self.tokenURL)
            HStack {
                SecureField("API token", text: $token)
                Button("Save") { lichess.saveToken(token); token = "" }.disabled(token.isEmpty)
            }
        } else if let account = lichess.account {
            LabeledContent("Signed in as") {
                HStack(spacing: 6) {
                    Text(account.username).bold()
                    Text(account.isBot ? "BOT" : "not a bot yet")
                        .font(.caption.bold())
                        .padding(.horizontal, 5)
                        .background((account.isBot ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                }
            }
            if account.isBot {
                LabeledContent("Ratings") {
                    Text(Self.ratings(account))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Upgrade \(account.username) to a BOT account…") { confirmUpgrade = true }
                    .confirmationDialog("Upgrade \(account.username) to BOT permanently?", isPresented: $confirmUpgrade) {
                        Button("Upgrade permanently", role: .destructive) { Task { await lichess.upgrade() } }
                    } message: {
                        Text("This cannot be undone. The account can then only play as a bot.")
                    }
            }
            Button("Forget token", role: .destructive) { lichess.forgetToken() }
        } else {
            HStack {
                Button("Connect") { Task { await lichess.connect() } }
                if lichess.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Forget token", role: .destructive) { lichess.forgetToken() }
            }
        }
    }

    private static func ratings(_ account: LichessAccount) -> String {
        let shown = ["blitz", "rapid", "classical", "correspondence"].compactMap { speed in
            account.ratings[speed].map { "\(speed) \($0)" }
        }
        return shown.isEmpty ? "none yet" : shown.joined(separator: " · ")
    }
}

// MARK: Stockfish match

private struct MatchSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(MatchDefaults.depthKey) private var depth = 10
    @AppStorage(MatchDefaults.whiteKey) private var personaWhite = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Depth for both") {
                    HStack {
                        Slider(value: Binding(get: { Double(depth) }, set: { depth = Int($0) }), in: 2...20, step: 1)
                        Text("\(depth) · \(Self.level(depth))")
                            .monospacedDigit()
                            .frame(width: 120, alignment: .trailing)
                    }
                }
                Picker("\(model.persona.name) plays", selection: $personaWhite) {
                    Text("White").tag(true)
                    Text("Black").tag(false)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("A game to watch at equal strength: Stockfish plays its best move at this depth, and \(model.persona.name)'s model picks among Stockfish's candidates at the same depth. Not counted, reviewed or saved. Start it from New Game ▸ Watch vs Stockfish (⌥⌘N).")
            }
        }
        .formStyle(.grouped)
    }

    /// A rough feel for the depth, not a measured rating.
    static func level(_ depth: Int) -> String {
        switch depth {
        case ..<5: "beginner"
        case ..<8: "club"
        case ..<12: "strong club"
        case ..<16: "master"
        default: "superhuman"
        }
    }
}
