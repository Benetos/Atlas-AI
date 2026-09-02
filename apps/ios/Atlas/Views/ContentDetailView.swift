import Foundation
import SwiftUI

struct ContentDetailView: View {
    @Environment(AppModel.self) private var model
    var dataset: String
    var externalID: String
    var sourceOrdinal: Int

    @State private var record: ContentRecord?
    @State private var fields: [ContentField] = []
    @State private var prettyPayload = ""
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading record…")
            } else if let record {
                List {
                    Section {
                        LabeledContent("Dataset", value: datasetTitle(record.dataset))
                        LabeledContent("Source ID", value: record.externalID)
                    }

                    if !fields.isEmpty {
                        Section("Details") {
                            ForEach(fields) { field in
                                LabeledContent(field.label, value: field.value)
                            }
                        }
                    }

                    Section {
                        DisclosureGroup("Raw source record") {
                            ScrollView(.horizontal) {
                                Text(prettyPayload)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.vertical, 8)
                            }
                        }
                    } footer: {
                        Text("This feature still uses Atlas’s lossless compatibility record. A dedicated screen can promote stable fields later.")
                    }
                }
            } else {
                ContentUnavailableView(
                    "Record not in this snapshot",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(errorMessage ?? "Atlas could not load this feature record.")
                )
            }
        }
        .navigationTitle(record?.title ?? "Record")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: routeKey) {
            await load()
        }
    }

    private var routeKey: String {
        "\(dataset):\(externalID):\(sourceOrdinal)"
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        guard let store = model.store else {
            errorMessage = "The local Atlas pack is unavailable."
            return
        }
        do {
            record = try store.content(dataset: dataset, id: externalID, sourceOrdinal: sourceOrdinal)
            guard let record else {
                errorMessage = "No matching record was found."
                return
            }
            let presentation = Self.present(payload: record.payload)
            fields = presentation.fields
            prettyPayload = presentation.prettyPayload
            errorMessage = nil
        } catch {
            record = nil
            errorMessage = error.localizedDescription
        }
    }

    private static func present(payload: String) -> (fields: [ContentField], prettyPayload: String) {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return ([], payload)
        }

        let fields: [ContentField]
        if let dictionary = object as? [String: Any] {
            fields = dictionary.keys.sorted().compactMap { key in
                guard let value = displayValue(dictionary[key]) else { return nil }
                return ContentField(label: fieldLabel(key), value: value)
            }
        } else {
            fields = []
        }

        let prettyData = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let prettyPayload = prettyData.flatMap { String(data: $0, encoding: .utf8) } ?? payload
        return (fields, prettyPayload)
    }

    private static func displayValue(_ value: Any?) -> String? {
        switch value {
        case nil, is NSNull:
            return nil
        case let string as String:
            return string.isEmpty ? nil : string
        case let number as NSNumber:
            return number.stringValue
        case let values as [Any]:
            return "\(values.count) item\(values.count == 1 ? "" : "s")"
        case let values as [String: Any]:
            return "\(values.count) field\(values.count == 1 ? "" : "s")"
        default:
            return String(describing: value as Any)
        }
    }

    private static func fieldLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func datasetTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct ContentField: Identifiable {
    var label: String
    var value: String

    var id: String { label }
}
