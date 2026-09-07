import Foundation

struct PackManifest: Equatable, Sendable {
    var packSchemaVersion: Int
    var contractVersion: Int
    var sourceRepository: String
    var sourceCommitSHA: String
    var sourceCommittedAt: String?
    var generatedAt: String
    var countsJSON: String

    var counts: [String: Int] {
        guard let data = countsJSON.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }

    var searchableRecordCount: Int {
        counts["entities", default: 0]
            + counts["recipes", default: 0]
            + counts["content_records", default: 0]
    }
}

enum EntityType: String, Codable, Sendable, CaseIterable, Identifiable {
    case product
    case substance
    case technology

    var id: String { rawValue }

    var title: String {
        switch self {
        case .product: "Products"
        case .substance: "Substances"
        case .technology: "Technology"
        }
    }

    var systemImage: String {
        switch self {
        case .product: "cube"
        case .substance: "drop"
        case .technology: "cpu"
        }
    }
}

enum RecipeKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case crafting
    case refining
    case cooking

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crafting: "Crafting"
        case .refining: "Refining"
        case .cooking: "Cooking"
        }
    }
}

struct Entity: Identifiable, Hashable, Sendable {
    var entityType: String
    var gameID: String
    var name: String?
    var displayName: String?
    var subtitle: String?
    var description: String?
    var category: String?
    var subcategory: String?
    var rarity: String?
    var legality: String?
    var baseValue: String?
    var colorR: String?
    var colorG: String?
    var colorB: String?
    var sourceDataset: String
    var sourceCommitSHA: String

    var id: String { "\(entityType):\(gameID)" }

    var title: String {
        let trimmedDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDisplay.isEmpty { return trimmedDisplay }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        return gameID
    }
}

struct Recipe: Identifiable, Hashable, Sendable {
    var recipeID: String
    var recipeKind: String
    var outputEntityType: String
    var outputGameID: String
    var outputAmount: String?
    var timeSeconds: String?
    var recipeType: String?
    var recipeName: String?
    var sourceOrdinal: Int
    var sourceCommitSHA: String
    var ingredients: [RecipeIngredient] = []
    var outputTitle: String?

    var id: String { recipeID }

    var title: String {
        if let recipeName, !recipeName.isEmpty { return recipeName }
        if let outputTitle, !outputTitle.isEmpty { return outputTitle }
        return recipeID
    }
}

struct RecipeIngredient: Identifiable, Hashable, Sendable {
    var recipeID: String
    var position: Int
    var entityType: String
    var gameID: String
    var amount: String?
    var title: String?

    var id: String { "\(recipeID):\(position)" }
}

struct ContentRecord: Identifiable, Hashable, Sendable {
    var dataset: String
    var externalID: String
    var sourceOrdinal: Int
    var displayName: String?
    var payload: String
    var sourceCommitSHA: String

    var id: String { "\(dataset):\(externalID):\(sourceOrdinal)" }

    var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return externalID
    }
}

struct WebHit: Identifiable, Hashable, Sendable {
    var title: String
    var url: URL
    var snippet: String
    var host: String
    var provenance: String

    var id: String { url.absoluteString }
}

enum AtlasCard: Identifiable, Hashable {
    case entity(Entity)
    case recipe(Recipe)
    case content(ContentRecord)
    case web(WebHit)

    var id: String {
        switch self {
        case .entity(let entity): "entity:\(entity.id)"
        case .recipe(let recipe): "recipe:\(recipe.id)"
        case .content(let record): "content:\(record.id)"
        case .web(let hit): "web:\(hit.id)"
        }
    }
}

struct AtlasMessage: Identifiable, Equatable {
    enum Role {
        case user
        case assistant
    }

    var id = UUID()
    var role: Role
    var text: String
    var cards: [AtlasCard] = []
    var note: String?
    var followUps: [ClarificationChip] = []
    var pendingActions: [PendingAction] = []
    var refreshRequired: Bool = false
    var packReleaseID: String?
}
