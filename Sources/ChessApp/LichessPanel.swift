import SwiftUI
import ChessAI

struct LichessPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        LichessPanelContent(lichess: model.lichess)
    }
}

private struct LichessPanelContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var lichess: LichessController
    @State private var token = ""
    @State private var confirmUpgrade = false
    @State private var opponentName = ""
    @State private var minutes = 10
    @State private var increment = 5
    /// Set in the Lobby; also used by the challenge-by-name in Play.
    @AppStorage("lichess.rated") private var rated = false
    @State private var aiLevel = 3

    private static let tokenURL = URL(string: "https://lichess.org/account/oauth/token/create?scopes[]=bot:play&description=ChessAi")!

    enum Section: String, CaseIterable { case bot = "Bot", play = "Play", lobby = "Lobby", activity = "Activity" }
    @AppStorage("lichess.section") private var section = Section.bot

    var body: some View {
        VStack(spacing: 0) {
            if lichess.account?.isBot == true {
                Picker("", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 12)
                switch section {
                case .bot: scrolling { accountSection; botSection }
                case .play: scrolling {
                    if let id = lichess.currentGame { gameSection(id) }
                    if !model.gameCalls.isEmpty { CostView(calls: model.gameCalls) }
                    challengeSection
                }
                case .lobby:
                    lobbySection.padding()
                        .task { if lichess.bots.isEmpty { await lichess.refreshBots() } }
                case .activity: scrolling { logSection }
                }
            } else {
                // Until the account is a BOT, only the account setup matters.
                scrolling { accountSection; logSection }
            }
        }
        .task { if lichess.hasToken && lichess.account == nil { await lichess.connect() } }
    }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .scrollIndicators(.visible)
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        GroupBox("Account") {
            VStack(alignment: .leading, spacing: 8) {
                if !lichess.hasToken {
                    Text("Use a separate Lichess account for the bot. Create an API token with the bot:play scope, then paste it here. It is kept in your Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("Create a token on lichess.org", destination: Self.tokenURL)
                    HStack {
                        SecureField("API token", text: $token)
                        Button("Save") { lichess.saveToken(token); token = "" }.disabled(token.isEmpty)
                    }
                } else if let account = lichess.account {
                    HStack {
                        Text(account.username).bold()
                        Text(account.isBot ? "BOT" : "not a bot yet")
                            .font(.caption.bold()).padding(.horizontal, 5)
                            .background((account.isBot ? Color.green : Color.orange).opacity(0.2), in: Capsule())
                        Spacer()
                        Button("Forget token", role: .destructive) { lichess.forgetToken() }
                    }
                    if account.isBot, account.ratings.isEmpty {
                        Text("No rating yet: only rated games count, and the first ones are provisional.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if account.isBot, !account.ratings.isEmpty {
                        Text(["rapid", "classical", "blitz", "correspondence"].compactMap { speed in
                            account.ratings[speed].map { "\(speed) \(String($0))" }
                        }.joined(separator: "  ·  "))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    if !account.isBot {
                        Text("Bots play through the Bot API, which needs a BOT account. The upgrade is permanent and only works on an account that has never played a game.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Upgrade \(account.username) to a BOT account…") { confirmUpgrade = true }
                            .confirmationDialog("Upgrade \(account.username) to BOT permanently?", isPresented: $confirmUpgrade) {
                                Button("Upgrade permanently", role: .destructive) { Task { await lichess.upgrade() } }
                            } message: {
                                Text("This cannot be undone. The account can then only play as a bot.")
                            }
                    }
                } else {
                    HStack {
                        Button("Connect") { Task { await lichess.connect() } }
                        if lichess.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Forget token", role: .destructive) { lichess.forgetToken() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Bot

    private var botSection: some View {
        GroupBox("Bot") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle().fill(lichess.running ? Color.green : Color.secondary).frame(width: 9, height: 9)
                    Text(lichess.running ? "\(model.persona.name) is online" : "Offline")
                    Spacer()
                    Button(lichess.running ? "Go offline" : "Go online") {
                        lichess.running ? lichess.stop() : lichess.start()
                    }
                    .disabled(!model.engineReady)
                }
                Text("Accepts").font(.caption.bold())
                HStack {
                    ForEach(["blitz", "rapid", "classical", "correspondence"], id: \.self) { speed in
                        Toggle(speed, isOn: Binding(
                            get: { lichess.settings.speeds.contains(speed) },
                            set: { on in if on { lichess.settings.speeds.insert(speed) } else { lichess.settings.speeds.remove(speed) } }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Toggle("rated", isOn: $lichess.settings.acceptRated).toggleStyle(.checkbox)
                    Toggle("casual", isOn: $lichess.settings.acceptCasual).toggleStyle(.checkbox)
                    Toggle("bots", isOn: $lichess.settings.acceptBots).toggleStyle(.checkbox)
                    Toggle("humans", isOn: $lichess.settings.acceptHumans).toggleStyle(.checkbox)
                }
                Text("With under 90 s on its clock it skips the model and plays Stockfish's top candidate. Blitz therefore plays mostly engine moves.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func gameSection(_ id: String) -> some View {
        GroupBox("Current game") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("vs \(lichess.opponent?.name ?? "?")\(lichess.opponent?.rating.map { " (\($0))" } ?? "")").bold()
                    Spacer()
                    Link("Open on Lichess", destination: URL(string: "https://lichess.org/\(id)")!)
                }
                Text("White \(Self.clock(lichess.clocks.white))   Black \(Self.clock(lichess.clocks.black))")
                    .font(.system(.callout, design: .monospaced))
                Button("Resign", role: .destructive) { lichess.resign() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var challengeSection: some View {
        GroupBox("Challenge") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Stepper("\(minutes) min", value: $minutes, in: 1...180)
                    Stepper("+\(increment) s", value: $increment, in: 0...60)
                }
                HStack {
                    TextField("Lichess username", text: $opponentName)
                    Button("Challenge") {
                        Task { await lichess.challenge(username: opponentName, minutes: minutes, increment: increment, rated: rated) }
                    }
                    .disabled(opponentName.isEmpty || !lichess.running)
                }
                HStack {
                    Stepper("Lichess AI level \(aiLevel)", value: $aiLevel, in: 1...8)
                    Button("Play it") { Task { await lichess.challengeAI(level: aiLevel, minutes: minutes, increment: increment) } }
                        .disabled(!lichess.running)
                }
                Text("Lichess AI is Stockfish at reduced strength, which makes it a good first test opponent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Lobby

    @State private var lobbyQuery = ""
    @State private var showBusy = false
    @State private var showUnrated = false

    private var lobbySection: some View {
        let speed = LichessController.speed(minutes: minutes, increment: increment)
        let target = 1500
        let busy = lichess.bots.filter { !lichess.isAvailable($0.username) }.count
        let shown = lichess.bots
            .filter { showBusy || lichess.isAvailable($0.username) }
            .filter { $0.ratings[speed] != nil || showUnrated }
            .filter { lobbyQuery.isEmpty || $0.username.localizedCaseInsensitiveContains(lobbyQuery) }
            .sorted { abs(($0.ratings[speed] ?? 0) - target) < abs(($1.ratings[speed] ?? 0) - target) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Filter by name", text: $lobbyQuery)
                    Button("Refresh") { Task { await lichess.refreshBots() } }
                    if lichess.busy { ProgressView().controlSize(.small) }
                }
                Toggle("Rated challenges (they count for \(model.persona.name)'s rating)", isOn: $rated).toggleStyle(.checkbox)
                HStack {
                    Toggle("show busy (\(busy))", isOn: $showBusy).toggleStyle(.checkbox)
                    Toggle("show unrated for \(speed)", isOn: $showUnrated).toggleStyle(.checkbox)
                }
                .font(.caption)
                Text("Ratings for \(speed) (\(minutes)+\(increment)), closest to 1500 first. Busy = hit Lichess's 100 bot games a day, or declined us recently. Challenges use the clock from Play.")
                    .font(.caption).foregroundStyle(.secondary)
                if lichess.bots.isEmpty { Text("Press Refresh to load the bots online now.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(shown.prefix(80)) { bot in
                            HStack {
                                Link(destination: URL(string: "https://lichess.org/@/\(bot.username)")!) {
                                    Text(bot.username).lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(bot.ratings[speed].map(String.init) ?? "–")
                                    .font(.system(.callout, design: .monospaced))
                                Text("\((bot.games[speed] ?? 0).formatted(.number.notation(.compactName))) games")
                                    .font(.caption).foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                                if !lichess.isAvailable(bot.username) {
                                    Text("busy").font(.caption2).foregroundStyle(.orange)
                                }
                                Button("Challenge") {
                                    Task { await lichess.challenge(username: bot.username, minutes: minutes, increment: increment, rated: rated) }
                                }
                                .disabled(!lichess.running || lichess.currentGame != nil)
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.trailing, 10)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity").font(.subheadline.bold())
            if lichess.log.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            ForEach(lichess.log.suffix(40).reversed()) { line in
                Text("\(line.date.formatted(date: .omitted, time: .standard))  \(line.text)")
                    .font(.caption)
                    .foregroundStyle(line.isError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private static func clock(_ ms: Int) -> String {
        guard ms < 86_400_000 else { return "∞" }
        let seconds = ms / 1000
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
