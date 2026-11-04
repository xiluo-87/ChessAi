import SwiftUI
import ChessAI

/// One tier's backend, model and effort, as a section of the Models settings.
struct TierSection: View {
    var title: String
    var hint: String
    @Binding var spec: ModelSpec
    @State private var models: [ModelCatalog.Entry] = []
    @State private var loading = false

    var body: some View {
        Section {
            Picker("Backend", selection: $spec.backend) {
                ForEach(BackendKind.allCases) { kind in
                    Text(kind.title + (ModelCatalog.installed(kind) ? "" : " (not installed)")).tag(kind)
                }
            }
            Picker("Model", selection: $spec.model) {
                if !models.contains(where: { $0.id == spec.model }) { Text(spec.model).tag(spec.model) }
                ForEach(models) { entry in
                    Text(entry.name + (entry.priceTier > 0 ? "  " + String(repeating: "$", count: entry.priceTier) : ""))
                        .tag(entry.id)
                }
            }
            .task(id: spec.backend) {
                loading = true
                models = await ModelCatalog.models(for: spec.backend)
                loading = false
                if spec.effort.map({ !(ModelCatalog.efforts[spec.backend] ?? []).contains($0) }) == true { spec.effort = nil }
            }
            TextField("Custom model id", text: $spec.model)
                .font(.system(.body, design: .monospaced))
            Picker("Effort", selection: Binding(get: { spec.effort ?? "" }, set: { spec.effort = $0.isEmpty ? nil : $0 })) {
                Text("default").tag("")
                ForEach(ModelCatalog.efforts[spec.backend] ?? [], id: \.self) { Text($0).tag($0) }
            }
        } header: {
            HStack {
                Text(title)
                if loading { ProgressView().controlSize(.small) }
            }
        } footer: {
            Text(hint)
        }
    }
}
