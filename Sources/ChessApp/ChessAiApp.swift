import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started as a plain executable (swift run), the process needs to become a regular app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count { snapshot(to: args[i + 1]) }
    }

    /// Development aid: renders the main view to a PNG and quits (`ChessAi --snapshot out.png`).
    @MainActor private func snapshot(to path: String) {
        let model = AppModel()
        // ImageRenderer draws no AppKit-backed views (split views, scroll views, pickers): render their contents.
        let view = HStack(alignment: .top, spacing: 20) {
            BoardView().frame(width: 560, height: 560)
            VStack(alignment: .leading, spacing: 12) {
                MoveListView()
                CostView(calls: [])
                NotesList(notes: model.persona.notes, empty: "No notes yet.")
            }
            .frame(width: 380, alignment: .topLeading)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(model)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ChessAiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ChessAi") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Game as White") { model.newGame(humanPlays: .white) }.keyboardShortcut("n")
                Button("New Game as Black") { model.newGame(humanPlays: .black) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = Tab.game

    enum Tab: String, CaseIterable { case game = "Game", lichess = "Lichess", memory = "Memory", models = "Models" }

    var body: some View {
        HSplitView {
            VStack(spacing: 12) {
                PlayerBar(lichess: model.lichess, top: true)
                BoardView()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(minWidth: 480, minHeight: 480)
                PlayerBar(lichess: model.lichess, top: false)
                HStack {
                    Text(model.status).font(.callout).foregroundStyle(.secondary)
                    if model.phase == .personaThinking || model.phase == .reviewing { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
            .padding()
            .layoutPriority(1)

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
                switch tab {
                case .game: GamePanel()
                case .lichess: LichessPanel()
                case .memory: MemoryPanel()
                case .models: ScrollView { ModelPickerForm().padding() }
                }
            }
            .frame(minWidth: 360, idealWidth: 400)
        }
        .alert("Problem", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}
