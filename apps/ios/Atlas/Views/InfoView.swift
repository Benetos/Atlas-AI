import SwiftUI

struct InfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Local snapshot") {
                    LabeledContent(
                        "Database",
                        value: databaseLabel
                    )
                    LabeledContent("Source commit", value: shortSHA(model.pack?.sourceCommitSHA))
                    LabeledContent("Contract", value: "\(model.pack?.contractVersion ?? 1)")
                    if let pack = model.pack {
                        LabeledContent("Items", value: formattedCount(pack.counts["entities"]))
                        LabeledContent("Recipes", value: formattedCount(pack.counts["recipes"]))
                        LabeledContent(
                            "Category records",
                            value: formattedCount(pack.counts["content_records"])
                        )
                    }
                    if let recovery = model.packRecoveryMessage {
                        Text(recovery)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if model.isPackUpdateRunning {
                        if let progress = model.packUpdateProgress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                    }
                    if let message = model.packUpdateMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Check for Database Update") {
                        Task { await model.refreshPack() }
                    }
                    .disabled(model.isPackUpdateRunning)
                }

                Section("Internet search") {
                    Toggle("Allow internet search", isOn: webSearchBinding)
                        .onChange(of: model.settings.webSearchEnabled) { _, enabled in
                            if enabled { model.settings.webSearchConfirmed = true }
                        }
                    Text("Web results are labeled community/web and never become Atlas recipes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("On-device AI") {
                    LabeledContent(
                        "Apple system model",
                        value: FoundationModelAvailability.current == .available ? "Available" : "Unavailable"
                    )
                    if FoundationModelAvailability.current == .unavailable {
                        Text("Grounded local search and cards still work. AI narration requires Apple’s on-device system model; Atlas never falls back to a cloud model.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Attribution") {
                    Text("Structured data is transformed from ApexFatality93/NMS-Handbook JSON at a pinned commit. Atlas does not reuse that project’s Python or website, and does not claim to own Hello Games material.")
                    Text("Extracted images are not bundled. Placeholders stand in for icons.")
                }
            }
            .navigationTitle("Info")
        }
    }

    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { model.settings.webSearchEnabled },
            set: { model.settings.webSearchEnabled = $0 }
        )
    }

    private func shortSHA(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return String(value.prefix(12))
    }

    private var databaseLabel: String {
        guard let pack = model.pack else { return "Unavailable" }
        if pack.searchableRecordCount < 1_000 {
            return "Sample Debug database"
        }
        return model.packRole == "production" ? "Full on-device database" : "Full Debug database"
    }

    private func formattedCount(_ value: Int?) -> String {
        (value ?? 0).formatted()
    }
}
