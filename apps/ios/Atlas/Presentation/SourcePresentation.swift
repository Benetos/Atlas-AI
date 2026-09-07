import Foundation

enum EvidenceSourceKind: String, Sendable, Hashable {
    case packed
    case liveAtlas
    case communityWeb
    case calculated

    var title: String {
        switch self {
        case .packed: "Packed"
        case .liveAtlas: "Live Atlas"
        case .communityWeb: "Community / web"
        case .calculated: "Calculated from pack"
        }
    }
}

struct PackIdentity: Hashable, Sendable {
    var sourceCommitSHA: String
    var packSchemaVersion: Int
    var contractVersion: Int
    var generatedAt: String
    var packRole: String?

    var releaseLabel: String {
        guard !sourceCommitSHA.isEmpty else { return "—" }
        return String(sourceCommitSHA.prefix(12))
    }

    init(
        sourceCommitSHA: String,
        packSchemaVersion: Int,
        contractVersion: Int,
        generatedAt: String,
        packRole: String? = nil
    ) {
        self.sourceCommitSHA = sourceCommitSHA
        self.packSchemaVersion = packSchemaVersion
        self.contractVersion = contractVersion
        self.generatedAt = generatedAt
        self.packRole = packRole
    }

    init(manifest: PackManifest, packRole: String?) {
        self.init(
            sourceCommitSHA: manifest.sourceCommitSHA,
            packSchemaVersion: manifest.packSchemaVersion,
            contractVersion: manifest.contractVersion,
            generatedAt: manifest.generatedAt,
            packRole: packRole
        )
    }
}

struct SourcePresentation: Hashable, Sendable {
    var kind: EvidenceSourceKind
    var releaseLabel: String?

    static func packed(_ identity: PackIdentity?) -> SourcePresentation {
        SourcePresentation(kind: .packed, releaseLabel: identity?.releaseLabel)
    }
}
