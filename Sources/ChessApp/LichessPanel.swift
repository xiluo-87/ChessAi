import SwiftUI
import ChessAI

struct LichessPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        LichessPanelContent(lichess: model.lichess)
    }
}

/// The clock and rated choice for challenges, shared by Play and Lobby.
private enum ChallengeDefaults {
    static let minutes = "lichess.minutes"
    static let increment = "lichess.increment"
    static let rated = "lichess.rated"
}

private struct LichessPanelContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lichess: LichessController
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settings.tab") private var settingsTab = SettingsTab.general
    @AppStorage(ChallengeDefaults.minutes) private var minutes = 10
    @AppStorage(ChallengeDefaults.increment) private var increment = 5

    enum Pane: String, CaseIterable { case play = "Play", lobby = "Lobby", activity = "Activity" }
    @AppStorage("lichess.pane") private var pane = Pane.lobby

    var body: some View {
        VStack(spacing: 0) {
            if let account = lichess.account, account.isBot {
                header(account)
                SubBar(selection: $pane, items: Pane.allCases) { $0.rawValue }
                Divider()
                switch pane {
                case .play: LichessPlayPane(lichess: lichess)
                case .lobby: LichessLobby(lichess: lichess)
                case .activity: LichessActivity(lichess: lichess)
                }
            } else {
                setup
            }
        }
        .task { if lichess.hasToken && lichess.account == nil { await lichess.connect() } }
    }

    private func header(_ account: LichessAccount) -> some View {
        let speed = LichessController.speed(minutes: minutes, increment: increment)
        return HStack(spacing: 8) {
            Circle()
                .fill(lichess.running ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(account.username).font(.headline).lineLimit(1)
            Text(account.ratings[speed].map { "\(speed) \($0)" } ?? "\(speed) unrated")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("Online", isOn: Binding(get: { lichess.running }, set: { $0 ? lichess.start() : lichess.stop() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!model.engineReady)
                .help(lichess.running ? "\(model.persona.name) accepts challenges and plays" : "Go online to play on Lichess")
            Button { openLichessSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Lichess settings")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    /// Until the account is a connected BOT, the panel only points to Settings.
    private var setup: some View {
        ContentUnavailableView {
            Label("Lichess bot", systemImage: "globe")
        } description: {
            Text(setupText)
        } actions: {
            if lichess.hasToken && lichess.account == nil {
                Button("Connect") { Task { await lichess.connect() } }.disabled(lichess.busy)
            }
            Button("Open Lichess Settings…") { openLichessSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var setupText: String {
        if !lichess.hasToken { return "Add the API token of a Lichess bot account in Settings." }
        guard let account = lichess.account else { return lichess.busy ? "Connecting…" : "Not connected." }
        return "\(account.username) is not a BOT account yet. Upgrade it in Settings."
    }

    private func openLichessSettings() {
        settingsTab = .lichess
        openSettings()
    }
}

// MARK: Play

private struct LichessPlayPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lichess: LichessController
    @AppStorage(ChallengeDefaults.minutes) private var minutes = 10
    @AppStorage(ChallengeDefaults.increment) private var increment = 5
    @AppStorage(ChallengeDefaults.rated) private var rated = false
    @State private var opponentName = ""
    @State private var aiLevel = 3

    var body: some View {
        Form {
            if let id = lichess.currentGame {
                Section("Current game") {
                    LabeledContent("Opponent") {
                        Text("\(lichess.opponent?.name ?? "?")\(lichess.opponent?.rating.map { " (\($0))" } ?? "")")
                    }
                    LabeledContent("Clock") {
                        Text("White \(lichessClock(lichess.clocks.white)) · Black \(lichessClock(lichess.clocks.black))")
                            .monospacedDigit()
                    }
                    HStack {
                        Link("Open on Lichess", destination: URL(string: "https://lichess.org/\(id)")!)
                        Spacer()
                        Button("Resign", role: .destructive) { lichess.resign() }
                    }
                    if !model.gameCalls.isEmpty { CostSummary(calls: model.gameCalls) }
                }
            }
            Section("Time control") {
                TimeControlPicker(minutes: $minutes, increment: $increment)
                Toggle("Rated", isOn: $rated)
            }
            Section {
                HStack {
                    TextField("Username", text: $opponentName, prompt: Text("Lichess username"))
                        .labelsHidden()
                    ChallengeStatus(state: opponentName.isEmpty ? nil : lichess.challengeState(opponentName))
                    Button("Challenge") {
                        Task { await lichess.challenge(username: opponentName, minutes: minutes, increment: increment, rated: rated) }
                    }
                    .disabled(opponentName.isEmpty || !canChallenge)
                }
            } header: {
                Text("Challenge a player")
            }
            Section {
                HStack {
                    Stepper("Level \(aiLevel)", value: $aiLevel, in: 1...8)
                    Spacer()
                    Button("Play") { Task { await lichess.challengeAI(level: aiLevel, minutes: minutes, increment: increment) } }
                        .disabled(!canChallenge)
                }
            } header: {
                HStack(spacing: 4) {
                    Text("Lichess AI")
                    InfoButton("Stockfish at reduced strength, run by Lichess: always available, so a good first opponent.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var canChallenge: Bool { lichess.running && lichess.currentGame == nil && !lichess.challengePending }
}

// MARK: Lobby

private struct LichessLobby: View {
    @ObservedObject var lichess: LichessController
    @AppStorage(ChallengeDefaults.minutes) private var minutes = 10
    @AppStorage(ChallengeDefaults.increment) private var increment = 5
    @AppStorage(ChallengeDefaults.rated) private var rated = false
    @AppStorage("lichess.lobby.ascending") private var ascending = false
    @State private var query = ""

    var body: some View {
        let speed = LichessController.speed(minutes: minutes, increment: increment)
        let bots = lichess.bots
            .filter { query.isEmpty || $0.username.localizedCaseInsensitiveContains(query) }
            .sorted { a, b in
                // Highest rating first (or lowest), bots without a rating at this speed last.
                guard let ra = a.ratings[speed] else { return false }
                guard let rb = b.ratings[speed] else { return true }
                return ascending ? ra < rb : ra > rb
            }
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Filter", text: $query, prompt: Text("Filter by name"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button { Task { await lichess.refreshBots() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload the bots online now")
                    .disabled(lichess.busy)
                InfoButton {
                    Text("The bots online on Lichess now. Ratings are for the speed of the chosen clock.")
                    Text("Greyed out: it has played its 100 bot games today, or declined us in the last hour.")
                    Text("A challenge it does not answer within 10 seconds is withdrawn.")
                }
            }
            HStack(spacing: 12) {
                TimeControlMenu(minutes: $minutes, increment: $increment)
                Toggle("Rated", isOn: $rated).toggleStyle(.checkbox)
                Spacer()
                if lichess.busy { ProgressView().controlSize(.mini) }
            }
            HStack(spacing: 8) {
                Text("\(bots.count) bots").frame(maxWidth: .infinity, alignment: .leading)
                Button { ascending.toggle() } label: {
                    HStack(spacing: 2) {
                        Text("Elo")
                        Image(systemName: ascending ? "chevron.up" : "chevron.down")
                    }
                }
                .buttonStyle(.borderless)
                .help(ascending ? "Lowest rating first" : "Highest rating first")
                .frame(width: LobbyRow.ratingWidth, alignment: .trailing)
                Text("Games").frame(width: LobbyRow.gamesWidth, alignment: .trailing)
                Color.clear.frame(width: LobbyRow.actionWidth, height: 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            Divider()
            if bots.isEmpty {
                ContentUnavailableView(
                    lichess.busy ? "Loading bots…" : "No bots", systemImage: "person.2",
                    description: Text(query.isEmpty ? "Reload to see the bots online now." : "No bot matches the filter."))
                    .frame(maxHeight: .infinity)
            } else {
                List(bots) { bot in
                    LobbyRow(bot: bot, speed: speed, lichess: lichess, minutes: minutes, increment: increment, rated: rated)
                }
                .listStyle(.plain)
            }
        }
        .padding([.horizontal, .top], 12)
        .task { if lichess.bots.isEmpty { await lichess.refreshBots() } }
    }
}

private struct LobbyRow: View {
    static let ratingWidth: CGFloat = 52
    static let gamesWidth: CGFloat = 48
    static let actionWidth: CGFloat = 96
    /// Tall enough for a status line, so a row keeps its height as a challenge changes state.
    static let height: CGFloat = 32

    let bot: LichessBotInfo
    let speed: String
    @ObservedObject var lichess: LichessController
    let minutes: Int
    let increment: Int
    let rated: Bool

    var body: some View {
        let state = lichess.challengeState(bot.username)
        let available = lichess.isAvailable(bot.username)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Link(destination: URL(string: "https://lichess.org/@/\(bot.username)")!) {
                    Text(bot.username).lineLimit(1).truncationMode(.middle)
                }
                if let line = statusLine(state, available) {
                    Text(line.text).font(.caption2).foregroundStyle(line.color).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(bot.ratings[speed].map(String.init) ?? "–")
                .monospacedDigit()
                .frame(width: Self.ratingWidth, alignment: .trailing)
            Text((bot.games[speed] ?? 0).formatted(.number.notation(.compactName)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.gamesWidth, alignment: .trailing)
            action(state, available)
                .frame(width: Self.actionWidth, alignment: .trailing)
        }
        .frame(height: Self.height)
        .opacity(available ? 1 : 0.5)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func action(_ state: LichessController.ChallengeState?, _ available: Bool) -> some View {
        if state?.isPending == true {
            ProgressView()
                .controlSize(.mini)
                .help("Waiting for \(bot.username) to answer")
        } else if state == .accepted {
            Label("Accepted", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Button("Challenge") {
                Task { await lichess.challenge(username: bot.username, minutes: minutes, increment: increment, rated: rated) }
            }
            .disabled(!available || blocked != nil)
            .help(blocked ?? (available ? "Challenge \(bot.username), \(minutes)+\(increment), \(rated ? "rated" : "casual")" : "Not available now"))
        }
    }

    /// Why no challenge can be sent to anyone right now.
    private var blocked: String? {
        if !lichess.running { return "Go online first" }
        if lichess.currentGame != nil { return "A game is in progress" }
        if lichess.challengePending { return "Waiting for another answer" }
        return nil
    }

    private func statusLine(_ state: LichessController.ChallengeState?, _ available: Bool) -> (text: String, color: Color)? {
        switch state {
        case .declined(let why)?: return ("Declined: \(why)", .orange)
        case .noAnswer?: return ("No answer, withdrawn", .secondary)
        case .failed(let why)?: return (why, .red)
        default: break
        }
        if !available, let until = lichess.unavailable[bot.username.lowercased()] {
            return ("Busy until \(until.formatted(date: .omitted, time: .shortened))", .secondary)
        }
        return nil
    }
}

/// How the latest challenge to one player went, next to the challenge-by-name field.
private struct ChallengeStatus: View {
    var state: LichessController.ChallengeState?

    var body: some View {
        switch state {
        case .sending?, .waiting?:
            ProgressView().controlSize(.mini)
        case .accepted?:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Accepted")
        case .declined(let why)?:
            Text(why).font(.caption).foregroundStyle(.orange)
        case .noAnswer?:
            Text("No answer").font(.caption).foregroundStyle(.secondary)
        case .failed(let why)?:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(why)
        case nil:
            EmptyView()
        }
    }
}

// MARK: Activity

private struct LichessActivity: View {
    @ObservedObject var lichess: LichessController

    var body: some View {
        if lichess.log.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "list.bullet")
                .frame(maxHeight: .infinity)
        } else {
            List(lichess.log.suffix(100).reversed()) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.date.formatted(date: .omitted, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(line.isError ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.plain)
        }
    }
}

func lichessClock(_ ms: Int) -> String {
    guard ms < 86_400_000 else { return "∞" }
    let seconds = ms / 1000
    return seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
