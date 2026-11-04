import SwiftUI

/// An ⓘ button whose explanation opens in a popover, so panels carry no paragraphs of help text.
struct InfoButton<Content: View>: View {
    @State private var shown = false
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("More information")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) { content }
                .font(.callout)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

extension InfoButton where Content == Text {
    init(_ text: String) {
        self.init { Text(text) }
    }
}

/// The second row of tabs inside a panel: smaller than the main tabs above it.
struct SubBar<Item: Hashable>: View {
    @Binding var selection: Item
    var items: [Item]
    var title: (Item) -> String

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(items, id: \.self) { Text(title($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A Lichess clock: minutes and increment in seconds.
struct TimeControl: Hashable, Identifiable {
    var minutes: Int
    var increment: Int

    var id: String { label }
    var label: String { "\(minutes)+\(increment)" }
    /// Lichess's speed for it ("blitz", "rapid", …), which picks the ratings that apply.
    var speed: String { LichessController.speed(minutes: minutes, increment: increment) }

    static let blitz = [TimeControl(minutes: 3, increment: 0), TimeControl(minutes: 3, increment: 2),
                        TimeControl(minutes: 5, increment: 0), TimeControl(minutes: 5, increment: 3)]
    static let rapid = [TimeControl(minutes: 10, increment: 0), TimeControl(minutes: 10, increment: 5),
                        TimeControl(minutes: 15, increment: 10)]
}

/// Blitz and rapid presets as two rows of segments.
struct TimeControlPicker: View {
    @Binding var minutes: Int
    @Binding var increment: Int

    var body: some View {
        let selection = Binding(
            get: { TimeControl(minutes: minutes, increment: increment) },
            set: { minutes = $0.minutes; increment = $0.increment })
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Blitz").foregroundStyle(.secondary)
                presets(TimeControl.blitz, selection)
            }
            GridRow {
                Text("Rapid").foregroundStyle(.secondary)
                presets(TimeControl.rapid, selection)
            }
        }
    }

    private func presets(_ list: [TimeControl], _ selection: Binding<TimeControl>) -> some View {
        // A row shows no segment selected while the clock is one of the other row's.
        Picker("", selection: selection) {
            ForEach(list) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The same presets as a compact menu, for toolbars and headers.
struct TimeControlMenu: View {
    @Binding var minutes: Int
    @Binding var increment: Int

    var body: some View {
        let current = TimeControl(minutes: minutes, increment: increment)
        Menu {
            Section("Blitz") { items(TimeControl.blitz, current) }
            Section("Rapid") { items(TimeControl.rapid, current) }
        } label: {
            Text("\(current.speed.capitalized) \(current.label)")
        }
        .fixedSize()
        .help("Time control for challenges; ratings shown are for its speed")
    }

    @ViewBuilder private func items(_ list: [TimeControl], _ current: TimeControl) -> some View {
        ForEach(list) { tc in
            Button {
                minutes = tc.minutes
                increment = tc.increment
            } label: {
                if tc == current { Label(tc.label, systemImage: "checkmark") } else { Text(tc.label) }
            }
        }
    }
}
