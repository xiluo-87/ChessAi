import SwiftUI
import ChessAI

struct SettingsView: View {
    var body: some View {
        ScrollView { ModelPickerForm().padding(20) }
            .frame(width: 520, height: 620)
    }
}

/// The model picker: one backend, model and effort per tier, plus the play and budget knobs.
struct ModelPickerForm: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TierPicker(
                title: "Strong model — thinks during the match",
                hint: "Asked only when several sound moves remain. Prompt-cached per game.",
                spec: $model.settings.routing.strong)
            TierPicker(
                title: "Cheap model — post-game notes and summaries",
                hint: "Two calls per game: the persona's notes, and its notes on you.",
                spec: $model.settings.routing.cheap)

            GroupBox("Play") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Strength (engine depth \(model.settings.play.engineDepth))") {
                        Slider(value: Binding(
                            get: { Double(model.settings.play.engineDepth) },
                            set: { model.settings.play.engineDepth = Int($0) }), in: 4...20, step: 1)
                    }
                    Stepper("Strong-model calls per game: \(model.settings.play.maxModelCalls)",
                            value: $model.settings.play.maxModelCalls, in: 0...80, step: 5)
                    Stepper("Candidate margin: \(model.settings.play.marginCp) cp",
                            value: $model.settings.play.marginCp, in: 10...200, step: 10)
                    Text("A wider margin gives the persona more freedom of style and costs strength. Calls set to 0 plays engine-only, free.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Your name", text: $model.settings.playerName)
                }
                .padding(6)
            }
            Text("Changes apply from the next game.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TierPicker: View {
    var title: String
    var hint: String
    @Binding var spec: ModelSpec
    @State private var models: [ModelCatalog.Entry] = []
    @State private var loading = false

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Backend", selection: $spec.backend) {
                    ForEach(BackendKind.allCases) { kind in
                        Text(kind.title + (ModelCatalog.installed(kind) ? "" : " — not installed")).tag(kind)
                    }
                }
                HStack {
                    Picker("Model", selection: $spec.model) {
                        if !models.contains(where: { $0.id == spec.model }) { Text(spec.model).tag(spec.model) }
                        ForEach(models) { entry in
                            Text(entry.name + (entry.priceTier > 0 ? "  " + String(repeating: "$", count: entry.priceTier) : ""))
                                .tag(entry.id)
                        }
                    }
                    if loading { ProgressView().controlSize(.small) }
                }
                TextField("Custom model id", text: $spec.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Picker("Effort", selection: Binding(get: { spec.effort ?? "" }, set: { spec.effort = $0.isEmpty ? nil : $0 })) {
                    Text("default").tag("")
                    ForEach(ModelCatalog.efforts[spec.backend] ?? [], id: \.self) { Text($0).tag($0) }
                }
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
        }
        .task(id: spec.backend) {
            loading = true
            models = await ModelCatalog.models(for: spec.backend)
            loading = false
            if spec.effort.map({ !(ModelCatalog.efforts[spec.backend] ?? []).contains($0) }) == true { spec.effort = nil }
        }
    }
}
