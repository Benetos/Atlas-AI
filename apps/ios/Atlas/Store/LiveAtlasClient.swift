import Foundation

enum LiveAtlasError: LocalizedError {
    case notConfigured
    case http(Int)
    case empty
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Live Atlas is not configured. Add the publishable key to Secrets.xcconfig."
        case .http(let code):
            return "Live Atlas request failed (\(code))."
        case .empty:
            return "Live Atlas returned no rows."
        case .invalidQuery:
            return "Live Atlas search had no usable characters."
        }
    }
}

struct LiveAtlasClient: Sendable {
    var baseURL: URL
    var anonKey: String

    init(settings: AppSettings) throws {
        guard let baseURL = settings.supabaseURL, !settings.supabaseAnonKey.isEmpty else {
            throw LiveAtlasError.notConfigured
        }
        self.baseURL = baseURL
        self.anonKey = settings.supabaseAnonKey
    }

    func sourceCommitSHA() async throws -> String {
        let rows: [LiveRevision] = try await get(
            path: "nms_entities",
            queryItems: [
                URLQueryItem(name: "select", value: "source_commit_sha"),
                URLQueryItem(name: "limit", value: "1"),
            ]
        )
        guard let sha = rows.first?.sourceCommitSHA, !sha.isEmpty else {
            throw LiveAtlasError.empty
        }
        return sha
    }

    func searchEntities(query: String, type: String?, limit: Int = 20) async throws -> [Entity] {
        let pattern = Self.ilikePattern(query)
        guard let pattern else { throw LiveAtlasError.invalidQuery }
        var items = [
            URLQueryItem(
                name: "select",
                value: "entity_type,game_id,name,display_name,subtitle,description,category,subcategory,rarity,legality,base_value,color_r,color_g,color_b,source_dataset,source_commit_sha"
            ),
            URLQueryItem(
                name: "or",
                value: "(display_name.ilike.\(pattern),name.ilike.\(pattern),game_id.ilike.\(pattern))"
            ),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let type, let safeType = Self.identifier(type) {
            items.append(URLQueryItem(name: "entity_type", value: "eq.\(safeType)"))
        }
        let rows: [LiveEntity] = try await get(path: "nms_entities", queryItems: items)
        return rows.map(\.asEntity)
    }

    func recipes(outputType: String, outputID: String) async throws -> [Recipe] {
        guard let type = Self.identifier(outputType), let id = Self.identifier(outputID) else {
            throw LiveAtlasError.invalidQuery
        }
        let rows: [LiveRecipe] = try await get(
            path: "nms_recipes",
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "recipe_id,recipe_kind,output_entity_type,output_game_id,output_amount,time_seconds,recipe_type,recipe_name,source_ordinal,source_commit_sha"
                ),
                URLQueryItem(name: "output_entity_type", value: "eq.\(type)"),
                URLQueryItem(name: "output_game_id", value: "eq.\(id)"),
            ]
        )
        return rows.map(\.asRecipe)
    }

    private func get<T: Decodable>(path: String, queryItems: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: baseURL.appending(path: "rest/v1/\(path)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems
        guard let url = components?.url else { throw LiveAtlasError.notConfigured }
        var request = URLRequest(url: url)
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw LiveAtlasError.http(code) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Builds a PostgREST `ilike` pattern from letters, numbers, and underscores only.
    static func ilikePattern(_ value: String) -> String? {
        let tokens = value.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "_"
        }
        guard !tokens.isEmpty else { return nil }
        return "*" + tokens.joined(separator: "*") + "*"
    }

    static func identifier(_ value: String) -> String? {
        let filtered = value.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" }
        return filtered.isEmpty ? nil : filtered
    }
}

private struct LiveRevision: Decodable {
    var sourceCommitSHA: String?

    enum CodingKeys: String, CodingKey {
        case sourceCommitSHA = "source_commit_sha"
    }
}

private struct LiveEntity: Decodable {
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
    var baseValue: Double?
    var colorR: Double?
    var colorG: Double?
    var colorB: Double?
    var sourceDataset: String?
    var sourceCommitSHA: String?

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case gameID = "game_id"
        case name
        case displayName = "display_name"
        case subtitle
        case description
        case category
        case subcategory
        case rarity
        case legality
        case baseValue = "base_value"
        case colorR = "color_r"
        case colorG = "color_g"
        case colorB = "color_b"
        case sourceDataset = "source_dataset"
        case sourceCommitSHA = "source_commit_sha"
    }

    var asEntity: Entity {
        Entity(
            entityType: entityType,
            gameID: gameID,
            name: name,
            displayName: displayName,
            subtitle: subtitle,
            description: description,
            category: category,
            subcategory: subcategory,
            rarity: rarity,
            legality: legality,
            baseValue: baseValue.map { String($0) },
            colorR: colorR.map { String($0) },
            colorG: colorG.map { String($0) },
            colorB: colorB.map { String($0) },
            sourceDataset: sourceDataset ?? "",
            sourceCommitSHA: sourceCommitSHA ?? ""
        )
    }
}

private struct LiveRecipe: Decodable {
    var recipeID: String
    var recipeKind: String
    var outputEntityType: String
    var outputGameID: String
    var outputAmount: Double?
    var timeSeconds: Double?
    var recipeType: String?
    var recipeName: String?
    var sourceOrdinal: Int
    var sourceCommitSHA: String?

    enum CodingKeys: String, CodingKey {
        case recipeID = "recipe_id"
        case recipeKind = "recipe_kind"
        case outputEntityType = "output_entity_type"
        case outputGameID = "output_game_id"
        case outputAmount = "output_amount"
        case timeSeconds = "time_seconds"
        case recipeType = "recipe_type"
        case recipeName = "recipe_name"
        case sourceOrdinal = "source_ordinal"
        case sourceCommitSHA = "source_commit_sha"
    }

    var asRecipe: Recipe {
        Recipe(
            recipeID: recipeID,
            recipeKind: recipeKind,
            outputEntityType: outputEntityType,
            outputGameID: outputGameID,
            outputAmount: outputAmount.map { String($0) },
            timeSeconds: timeSeconds.map { String($0) },
            recipeType: recipeType,
            recipeName: recipeName,
            sourceOrdinal: sourceOrdinal,
            sourceCommitSHA: sourceCommitSHA ?? "",
            ingredients: [],
            outputTitle: recipeName
        )
    }
}
