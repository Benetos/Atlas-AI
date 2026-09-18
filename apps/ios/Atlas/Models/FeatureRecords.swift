import Foundation

enum SpecialistFeature: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case fish
    case bait
    case buildingParts = "building_parts"
    case shipParts = "ship_parts"
    case corvetteParts = "corvette_parts"
    case specialRewards = "special_rewards"
    case specialPurchases = "special_purchases"
    case fossils
    case legacyItems = "legacy_items"
    case buildingBlueprints = "purchaseable_building_blueprints"
    case stories

    var id: String { rawValue }
    var dataset: String { rawValue }

    var tableName: String {
        switch self {
        case .fish: "nms_fish"
        case .bait: "nms_bait"
        case .buildingParts: "nms_building_parts"
        case .shipParts: "nms_ship_parts"
        case .corvetteParts: "nms_corvette_parts"
        case .specialRewards: "nms_special_rewards"
        case .specialPurchases: "nms_special_purchases"
        case .fossils: "nms_fossils"
        case .legacyItems: "nms_legacy_items"
        case .buildingBlueprints: "nms_building_blueprints"
        case .stories: "nms_stories"
        }
    }

    var title: String {
        switch self {
        case .fish: "Fish"
        case .bait: "Bait"
        case .buildingParts: "Building Parts"
        case .shipParts: "Ship Parts"
        case .corvetteParts: "Corvette Parts"
        case .specialRewards: "Special Rewards"
        case .specialPurchases: "Special Purchases"
        case .fossils: "Fossils"
        case .legacyItems: "Legacy Items"
        case .buildingBlueprints: "Building Blueprints"
        case .stories: "Stories"
        }
    }

    var systemImage: String {
        switch self {
        case .fish: "fish"
        case .bait: "circle.hexagongrid"
        case .buildingParts: "hammer"
        case .shipParts: "airplane"
        case .corvetteParts: "airplane.circle"
        case .specialRewards: "gift"
        case .specialPurchases: "bag"
        case .fossils: "fossil.shell"
        case .legacyItems: "clock.arrow.circlepath"
        case .buildingBlueprints: "building.2"
        case .stories: "book"
        }
    }

    var placeholderEntityType: String {
        switch self {
        case .fish, .bait, .fossils, .legacyItems, .specialPurchases, .specialRewards:
            "product"
        case .buildingParts, .buildingBlueprints, .corvetteParts:
            "technology"
        case .shipParts:
            "technology"
        case .stories:
            "product"
        }
    }

    var hidesDisabledByDefault: Bool {
        switch self {
        case .buildingParts, .corvetteParts: true
        default: false
        }
    }

    var supportsCompare: Bool {
        self != .stories
    }

    var supportsChecklist: Bool {
        switch self {
        case .buildingParts, .corvetteParts, .stories: true
        default: false
        }
    }

    init?(dataset: String) {
        self.init(rawValue: dataset)
    }
}

enum PackedFishMembership {
    static let anyTime = "Both"
    static let night = "Night"
    static let day = "Day"
    static let anyBiome = "All"

    static func matchesTime(_ packed: String, selected: String) -> Bool {
        if selected == night || selected == day {
            return packed == selected || packed == anyTime
        }
        return packed == selected
    }

    static func matchesBiome(_ packed: String, selected: String) -> Bool {
        if selected == anyBiome {
            return packed == anyBiome
        }
        return packed == selected || packed == anyBiome
    }
}

struct SpecialistQuery: Equatable, Sendable {
    var feature: SpecialistFeature
    var search: String = ""
    var timeOfDay: String?
    var biome: String?
    var size: String?
    var quality: String?
    var needsStorm: Bool?
    var usedFor: String?
    var shipType: String?
    var category: String?
    var includeNotEnabled: Bool = false
    var requiredEntityType: String?
    var requiredGameID: String?
    var limit: Int = 60
    var offset: Int = 0
}

struct SpecialistRoute: Hashable, Codable, Sendable {
    var feature: SpecialistFeature
    var search: String = ""
    var timeOfDay: String?
    var biome: String?
    var size: String?
    var quality: String?
    var needsStorm: Bool?
    var usedFor: String?
    var shipType: String?
    var category: String?
    var includeNotEnabled: Bool = false
    var requiredEntityType: String?
    var requiredGameID: String?

    var query: SpecialistQuery {
        SpecialistQuery(
            feature: feature,
            search: search,
            timeOfDay: timeOfDay,
            biome: biome,
            size: size,
            quality: quality,
            needsStorm: needsStorm,
            usedFor: usedFor,
            shipType: shipType,
            category: category,
            includeNotEnabled: includeNotEnabled,
            requiredEntityType: requiredEntityType,
            requiredGameID: requiredGameID
        )
    }

    var destination: AppDestination { .specialist(self) }

    var chipLabel: String {
        switch feature {
        case .fish: "Open fish guide"
        case .shipParts: "Open ship parts"
        case .buildingParts: "Open building checklist"
        case .corvetteParts: "Open corvette parts"
        default: "Open \(feature.title.lowercased())"
        }
    }

    var filterSummary: String {
        var parts: [String] = []
        if let timeOfDay, !timeOfDay.isEmpty { parts.append(timeOfDay) }
        if let biome, !biome.isEmpty { parts.append(biome) }
        if let size, !size.isEmpty { parts.append(size) }
        if let quality, !quality.isEmpty { parts.append(quality) }
        if needsStorm == true { parts.append("storm") }
        if let usedFor, !usedFor.isEmpty { parts.append(usedFor) }
        if let shipType, !shipType.isEmpty { parts.append(shipType) }
        if let category, !category.isEmpty { parts.append(category) }
        if !search.isEmpty { parts.append(search) }
        if let requiredGameID, !requiredGameID.isEmpty { parts.append(requiredGameID) }
        return parts.joined(separator: " · ")
    }
}

struct SpecialistFilterOptions: Equatable, Sendable {
    var times: [String] = []
    var biomes: [String] = []
    var sizes: [String] = []
    var qualities: [String] = []
    var usedFor: [String] = []
    var shipTypes: [String] = []
    var categories: [String] = []

    static let empty = SpecialistFilterOptions()
}

struct SpecialistSummary: Identifiable, Hashable, Sendable {
    var feature: SpecialistFeature
    var externalID: String
    var sourceOrdinal: Int
    var title: String
    var subtitle: String?
    var iconSourcePath: String?
    var badges: [String]
    var notEnabled: Bool

    var id: String { "\(feature.dataset):\(externalID):\(sourceOrdinal)" }

    var destination: AppDestination {
        .content(dataset: feature.dataset, id: externalID, sourceOrdinal: sourceOrdinal)
    }
}

struct SpecialistRequirement: Identifiable, Hashable, Sendable {
    var position: Int
    var entityType: String?
    var gameID: String?
    var amount: String?
    var title: String?

    var id: Int { position }

    var label: String {
        title ?? gameID ?? "Requirement \(position + 1)"
    }
}

struct SpecialistStoryPage: Identifiable, Hashable, Sendable {
    var position: Int
    var title: String?
    var entries: [SpecialistStoryEntry]

    var id: Int { position }
}

struct SpecialistStoryEntry: Identifiable, Hashable, Sendable {
    var pagePosition: Int
    var position: Int
    var title: String?
    var body: String?

    var id: String { "\(pagePosition):\(position)" }
}

struct SpecialistDetail: Identifiable, Hashable, Sendable {
    var summary: SpecialistSummary
    var fields: [ContentField]
    var biomes: [String]
    var requirements: [SpecialistRequirement]
    var categories: [String]
    var rewardSources: [String]
    var storyPages: [SpecialistStoryPage]
    var extraFields: [ContentField]
    var prettyPayload: String

    var id: String { summary.id }
}

enum PackedIconLocator {
    static func relativePath(fromSourcePath source: String?) -> String? {
        guard var path = source?.replacingOccurrences(of: "\\", with: "/"),
              !path.isEmpty else { return nil }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        if path.lowercased().hasSuffix(".dds") {
            path = String(path.dropLast(4)) + ".png"
        } else if !path.lowercased().hasSuffix(".png") {
            path += ".png"
        }
        return "icons/" + path.lowercased()
    }

    static func fileURL(sourcePath: String?, packDirectory: URL?) -> URL? {
        guard let relative = relativePath(fromSourcePath: sourcePath) else { return nil }
        var candidates: [URL] = []
        if let packDirectory {
            candidates.append(packDirectory.appending(path: relative))
        }
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appending(path: relative))
        }
        candidates.append(Bundle.main.bundleURL.appending(path: relative))
        let fileName = URL(fileURLWithPath: relative).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: relative).pathExtension
        let subdirectory = URL(fileURLWithPath: relative).deletingLastPathComponent().path
        if let bundled = Bundle.main.url(
            forResource: fileName,
            withExtension: ext.isEmpty ? nil : ext,
            subdirectory: subdirectory.isEmpty ? nil : subdirectory
        ) {
            candidates.append(bundled)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
