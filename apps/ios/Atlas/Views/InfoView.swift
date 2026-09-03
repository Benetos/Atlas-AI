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

                Section("Live Atlas") {
                    Toggle("Allow explicit live comparison", isOn: liveAtlasBinding)
                    Text("Atlas database tools always use the installed SQLite pack. Live Atlas is contacted only when you explicitly ask for it, and never replaces a local error or missing result.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.settings.liveAtlasEnabled {
                        if let live = model.liveRevision {
                            LabeledContent("Live commit", value: shortSHA(live))
                            if let local = model.pack?.sourceCommitSHA, live != local {
                                Text("The live and packed revisions differ. Recipe facts still prefer the local snapshot unless you ask to search live Atlas.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else if let error = model.liveRevisionError {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
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
                    Text("Structured data is transformed from ApexFatality93/NMS-Handbook (GPL-3.0) at a pinned commit. Much of that text and imagery is extracted from No Man’s Sky and may contain rights owned by Hello Games or its licensors.")
                    Text("Extracted images are not bundled. Placeholders stand in until the Phase 0 publication gate.")
                    Text("Licensing posture: internal until Phase 0 is written.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Info")
            .task {
                await model.refreshLiveRevision()
            }
            .onChange(of: model.settings.liveAtlasEnabled) {
                Task { await model.refreshLiveRevision() }
            }
        }
    }

    private var liveAtlasBinding: Binding<Bool> {
        Binding(
            get: { model.settings.liveAtlasEnabled },
            set: { model.settings.liveAtlasEnabled = $0 }
        )
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
