import SwiftUI

struct InfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section("Local snapshot") {
                    LabeledContent("Source commit", value: shortSHA(model.pack?.sourceCommitSHA))
                    LabeledContent("Contract", value: "\(model.pack?.contractVersion ?? 1)")
                    if let counts = model.pack?.countsJSON {
                        Text(counts)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Live Atlas") {
                    Toggle("Use live Atlas data", isOn: liveAtlasBinding)
                    if model.settings.liveAtlasEnabled {
                        if let live = model.liveRevision {
                            LabeledContent("Live commit", value: shortSHA(live))
                            if let local = model.pack?.sourceCommitSHA, live != local {
                                Text("Live data is newer than this pack. Recipe facts still prefer the local snapshot unless you ask to search live Atlas.")
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

                Section("Apple Intelligence") {
                    LabeledContent(
                        "Foundation Models",
                        value: FoundationModelAvailability.current == .available ? "Available" : "Unavailable"
                    )
                    if FoundationModelAvailability.current == .unavailable {
                        Text("The composer still runs local search. Atlas chat needs Apple Intelligence on iOS 26.")
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
}
