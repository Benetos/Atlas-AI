import Foundation

enum LiveAtlasError: LocalizedError {
    case notConfigured
    case http(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Live Atlas is not configured. Add the publishable key to Secrets.xcconfig."
        case .http(let code):
            return "Live Atlas request failed (\(code))."
        case .empty:
            return "Live Atlas returned no rows."
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
        let rows: [LiveEntity] = try await get(
            path: "nms_entities",
            query: "select=source_commit_sha&limit=1"
        )
        guard let sha = rows.first?.sourceCommitSHA, !sha.isEmpty else {
            throw LiveAtlasError.empty
        }
        return sha
    }

    func searchEntities(query: String, type: String?, limit: Int = 20) async throws -> [Entity] {
        var filters = [
            "select=entity_type,game_id,name,display_name,subtitle,description,category,subcategory,rarity,legality,base_value,color_r,color_g,color_b,source_dataset,source_commit_sha",
            "or=(display_name.ilike.*\(Self.sanitize(query))*,name.ilike.*\(Self.sanitize(query))*,game_id.ilike.*\(Self.sanitize(query))*)",
            "limit=\(limit)",
        ]
        if let type {
            filters.append("entity_type=eq.\(type)")
        }
        let rows: [LiveEntity] = try await get(path: "nms_entities", query: filters.joined(separator: "&"))
        return rows.map(\.asEntity)
    }

    func recipes(outputType: String, outputID: String) async throws -> [Recipe] {
        let rows: [LiveRecipe] = try await get(
            path: "nms_recipes",
            query: "select=recipe_id,recipe_kind,output_entity_type,output_game_id,output_amount,time_seconds,recipe_type,recipe_name,source_ordinal,source_commit_sha&output_entity_type=eq.\(outputType)&output_game_id=eq.\(outputID)"
        )
        return rows.map(\.asRecipe)
    }

    private func get<T: Decodable>(path: String, query: String) async throws -> T {
        var components = URLComponents(
            url: baseURL.appending(path: "rest/v1/\(path)"),
            resolvingAgainstBaseURL: false
        )
        components?.percentEncodedQuery = query
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

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "&", with: " ")
            .replacingOccurrences(of: "*", with: " ")
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
