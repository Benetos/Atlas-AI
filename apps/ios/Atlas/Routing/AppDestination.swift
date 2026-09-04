import Foundation

enum AppSection: String, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case atlas
    case library
    case saved
    case info

    var id: String { rawValue }

    var title: String {
        switch self {
        case .atlas: "Atlas"
        case .library: "Library"
        case .saved: "Saved"
        case .info: "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .atlas: "sparkles"
        case .library: "books.vertical"
        case .saved: "bookmark"
        case .info: "info.circle"
        }
    }
}

enum UnavailableReason: String, Codable, Hashable, Sendable {
    case notFound
    case capabilityUnavailable
    case packStale
    case deleted
}

struct UnavailableDestination: Hashable, Codable, Sendable {
    var title: String
    var reason: UnavailableReason
    var recordKey: String?
    var canDeleteReference: Bool
}

enum AppDestination: Hashable, Codable, Sendable {
    case entity(type: String, id: String)
    case recipe(id: String)
    case content(dataset: String, id: String, sourceOrdinal: Int)
    case savedArtifact(id: String)
    case unavailable(UnavailableDestination)

    private static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case kind
        case entityType
        case id
        case dataset
        case sourceOrdinal
        case artifactID
        case unavailable
    }

    private enum Kind: String, Codable {
        case entity
        case recipe
        case content
        case savedArtifact
        case unavailable
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .entity(let type, let id):
            try container.encode(Kind.entity, forKey: .kind)
            try container.encode(type, forKey: .entityType)
            try container.encode(id, forKey: .id)
        case .recipe(let id):
            try container.encode(Kind.recipe, forKey: .kind)
            try container.encode(id, forKey: .id)
        case .content(let dataset, let id, let sourceOrdinal):
            try container.encode(Kind.content, forKey: .kind)
            try container.encode(dataset, forKey: .dataset)
            try container.encode(id, forKey: .id)
            try container.encode(sourceOrdinal, forKey: .sourceOrdinal)
        case .savedArtifact(let id):
            try container.encode(Kind.savedArtifact, forKey: .kind)
            try container.encode(id, forKey: .artifactID)
        case .unavailable(let destination):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(destination, forKey: .unavailable)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            self = .unavailable(
                UnavailableDestination(
                    title: "Unsupported route",
                    reason: .capabilityUnavailable,
                    recordKey: nil,
                    canDeleteReference: false
                )
            )
            return
        }
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .entity:
            self = .entity(
                type: try container.decode(String.self, forKey: .entityType),
                id: try container.decode(String.self, forKey: .id)
            )
        case .recipe:
            self = .recipe(id: try container.decode(String.self, forKey: .id))
        case .content:
            self = .content(
                dataset: try container.decode(String.self, forKey: .dataset),
                id: try container.decode(String.self, forKey: .id),
                sourceOrdinal: try container.decode(Int.self, forKey: .sourceOrdinal)
            )
        case .savedArtifact:
            self = .savedArtifact(id: try container.decode(String.self, forKey: .artifactID))
        case .unavailable:
            self = .unavailable(try container.decode(UnavailableDestination.self, forKey: .unavailable))
        }
    }
}
