import Foundation

struct EntityDetailContent: Sendable {
    var entity: Entity
    var produced: [Recipe]
    var usedIn: [Recipe]
    var provenance: SourcePresentation
}

struct RecipeDetailContent: Sendable {
    var recipe: Recipe
    var provenance: SourcePresentation
}

struct ContentDetailContent: Sendable {
    var record: ContentRecord
    var fields: [ContentField]
    var prettyPayload: String
    var provenance: SourcePresentation
}

struct ContentField: Identifiable, Hashable, Sendable {
    var key: String
    var label: String
    var value: String

    var id: String { key }
}

@MainActor
@Observable
final class EntityDetailModel {
    var state: LoadState<EntityDetailContent> = .idle
    private var loadGeneration: UInt64 = 0

    func load(
        type: String,
        id: String,
        catalog: any NMSCatalog,
        packIdentity: PackIdentity?
    ) async {
        loadGeneration += 1
        let token = loadGeneration
        state = .loading
        do {
            let entity = try await catalog.entity(type: type, id: id)
            try Task.checkCancellation()
            guard token == loadGeneration else { return }
            let produced = try await catalog.recipesProducing(type: type, id: id)
            let usedIn = try await catalog.recipesUsing(type: type, id: id)
            guard token == loadGeneration else { return }
            state = .loaded(
                EntityDetailContent(
                    entity: entity,
                    produced: produced,
                    usedIn: usedIn,
                    provenance: .packed(packIdentity)
                )
            )
        } catch is CancellationError {
            return
        } catch let error as CatalogError {
            guard token == loadGeneration else { return }
            switch error {
            case .notFound:
                state = .notFound
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard token == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
final class RecipeDetailModel {
    var state: LoadState<RecipeDetailContent> = .idle
    private var loadGeneration: UInt64 = 0

    func load(id: String, catalog: any NMSCatalog, packIdentity: PackIdentity?) async {
        loadGeneration += 1
        let token = loadGeneration
        state = .loading
        do {
            let recipe = try await catalog.recipe(id: id)
            try Task.checkCancellation()
            guard token == loadGeneration else { return }
            state = .loaded(
                RecipeDetailContent(recipe: recipe, provenance: .packed(packIdentity))
            )
        } catch is CancellationError {
            return
        } catch let error as CatalogError {
            guard token == loadGeneration else { return }
            switch error {
            case .notFound:
                state = .notFound
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard token == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
final class ContentDetailModel {
    var state: LoadState<ContentDetailContent> = .idle
    private var loadGeneration: UInt64 = 0

    func load(
        dataset: String,
        id: String,
        sourceOrdinal: Int,
        catalog: any NMSCatalog,
        packIdentity: PackIdentity?
    ) async {
        loadGeneration += 1
        let token = loadGeneration
        state = .loading
        do {
            let record = try await catalog.content(
                dataset: dataset,
                id: id,
                sourceOrdinal: sourceOrdinal
            )
            try Task.checkCancellation()
            guard token == loadGeneration else { return }
            let presentation = ContentDetailPresenter.present(payload: record.payload)
            state = .loaded(
                ContentDetailContent(
                    record: record,
                    fields: presentation.fields,
                    prettyPayload: presentation.prettyPayload,
                    provenance: .packed(packIdentity)
                )
            )
        } catch is CancellationError {
            return
        } catch let error as CatalogError {
            guard token == loadGeneration else { return }
            switch error {
            case .notFound:
                state = .notFound
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard token == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

enum ContentDetailPresenter {
    static func present(payload: String) -> (fields: [ContentField], prettyPayload: String) {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return ([], payload)
        }

        let fields: [ContentField]
        if let dictionary = object as? [String: Any] {
            fields = dictionary.keys.sorted().compactMap { key in
                guard let value = displayValue(dictionary[key]) else { return nil }
                return ContentField(key: key, label: fieldLabel(key), value: value)
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
        case let boolean as Bool:
            return boolean ? "true" : "false"
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
}
