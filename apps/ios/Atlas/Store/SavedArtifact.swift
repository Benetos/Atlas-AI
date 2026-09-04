import Foundation

enum SavedArtifactKind: String, Sendable {
    case bookmark
    case recipePlan
}

enum BookmarkTarget: Hashable, Sendable {
    case entity(type: String, gameID: String)
    case recipe(id: String)

    var kind: SavedItem.Kind {
        switch self {
        case .entity: .entity
        case .recipe: .recipe
        }
    }

    var entityType: String? {
        if case .entity(let type, _) = self { return type }
        return nil
    }

    var gameID: String? {
        if case .entity(_, let gameID) = self { return gameID }
        return nil
    }

    var recipeID: String? {
        if case .recipe(let id) = self { return id }
        return nil
    }

    var stableID: String {
        switch self {
        case .entity(let type, let gameID):
            return "entity:\(type):\(gameID)"
        case .recipe(let id):
            return "recipe:\(id)"
        }
    }

    var destination: AppDestination {
        switch self {
        case .entity(let type, let gameID):
            return .entity(type: type, id: gameID)
        case .recipe(let id):
            return .recipe(id: id)
        }
    }
}

struct SavedItem: Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case entity
        case recipe
    }

    var kind: Kind
    var entityType: String?
    var gameID: String?
    var recipeID: String?
    var title: String
    var savedAt: Date
    var originatingPackReleaseID: String?

    var id: String {
        target.stableID
    }

    var target: BookmarkTarget {
        switch kind {
        case .entity:
            return .entity(type: entityType ?? "", gameID: gameID ?? "")
        case .recipe:
            return .recipe(id: recipeID ?? "")
        }
    }

    var destination: AppDestination { target.destination }

    static func entity(_ entity: Entity, savedAt: Date, packReleaseID: String?) -> SavedItem {
        SavedItem(
            kind: .entity,
            entityType: entity.entityType,
            gameID: entity.gameID,
            recipeID: nil,
            title: entity.title,
            savedAt: savedAt,
            originatingPackReleaseID: packReleaseID
        )
    }

    static func recipe(_ recipe: Recipe, savedAt: Date, packReleaseID: String?) -> SavedItem {
        SavedItem(
            kind: .recipe,
            entityType: recipe.outputEntityType,
            gameID: recipe.outputGameID,
            recipeID: recipe.recipeID,
            title: recipe.title,
            savedAt: savedAt,
            originatingPackReleaseID: packReleaseID
        )
    }
}

struct SavedArtifactRecord: Equatable, Sendable {
    var id: String
    var kind: String
    var payloadVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var originatingPackReleaseID: String?
    var originatingCapabilities: [String]
    var payloadData: Data

    var payload: [String: Any] {
        (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
    }

    init(
        id: String,
        kind: String,
        payloadVersion: Int,
        createdAt: Date,
        updatedAt: Date,
        originatingPackReleaseID: String?,
        originatingCapabilities: [String],
        payload: [String: Any]
    ) {
        self.id = id
        self.kind = kind
        self.payloadVersion = payloadVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originatingPackReleaseID = originatingPackReleaseID
        self.originatingCapabilities = originatingCapabilities
        self.payloadData = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
    }

    func bookmark() -> SavedItem? {
        guard kind == SavedArtifactKind.bookmark.rawValue else { return nil }
        let title = payload["title"] as? String ?? id
        let targetKind = payload["targetKind"] as? String
        switch targetKind {
        case "entity":
            return SavedItem(
                kind: .entity,
                entityType: payload["entityType"] as? String,
                gameID: payload["gameID"] as? String,
                recipeID: nil,
                title: title,
                savedAt: createdAt,
                originatingPackReleaseID: originatingPackReleaseID
            )
        case "recipe":
            return SavedItem(
                kind: .recipe,
                entityType: payload["entityType"] as? String,
                gameID: payload["gameID"] as? String,
                recipeID: payload["recipeID"] as? String,
                title: title,
                savedAt: createdAt,
                originatingPackReleaseID: originatingPackReleaseID
            )
        default:
            return nil
        }
    }

    func recipePlan() -> SavedRecipePlan? {
        guard kind == SavedArtifactKind.recipePlan.rawValue else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return try? SavedRecipePlan.decoder.decode(SavedRecipePlan.self, from: data)
    }

    static func bookmark(
        from item: SavedItem,
        existing: SavedArtifactRecord?,
        now: Date
    ) -> SavedArtifactRecord {
        var payload: [String: Any] = [
            "title": item.title,
            "targetKind": item.kind.rawValue,
        ]
        if let entityType = item.entityType { payload["entityType"] = entityType }
        if let gameID = item.gameID { payload["gameID"] = gameID }
        if let recipeID = item.recipeID { payload["recipeID"] = recipeID }
        return SavedArtifactRecord(
            id: item.id,
            kind: SavedArtifactKind.bookmark.rawValue,
            payloadVersion: 1,
            createdAt: existing?.createdAt ?? item.savedAt,
            updatedAt: now,
            originatingPackReleaseID: item.originatingPackReleaseID,
            originatingCapabilities: existing?.originatingCapabilities ?? [],
            payload: payload
        )
    }

    static func recipePlan(
        from plan: SavedRecipePlan,
        existing: SavedArtifactRecord?,
        now: Date
    ) -> SavedArtifactRecord {
        let data = (try? SavedRecipePlan.encoder.encode(plan)) ?? Data("{}".utf8)
        let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return SavedArtifactRecord(
            id: plan.id,
            kind: SavedArtifactKind.recipePlan.rawValue,
            payloadVersion: 1,
            createdAt: existing?.createdAt ?? plan.createdAt,
            updatedAt: now,
            originatingPackReleaseID: plan.packReleaseID,
            originatingCapabilities: existing?.originatingCapabilities ?? ["recipe-planner"],
            payload: payload
        )
    }
}

struct SavedArtifactsSnapshot: Equatable, Sendable {
    var bookmarks: [SavedItem]
    var recents: [SavedItem]
    var recipePlans: [SavedRecipePlan]
    var records: [SavedArtifactRecord]
}
