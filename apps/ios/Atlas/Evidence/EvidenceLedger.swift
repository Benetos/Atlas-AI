import CryptoKit
import Foundation

enum RecordKey: Hashable, Sendable, Codable, Equatable {
    case entity(type: String, id: String)
    case recipe(id: String)
    case content(dataset: String, id: String, sourceOrdinal: Int)
    case web(url: String)
    case derived(id: String)

    var canonical: String {
        switch self {
        case .entity(let type, let id):
            return "entity:\(type):\(id)"
        case .recipe(let id):
            return "recipe:\(id)"
        case .content(let dataset, let id, let ordinal):
            return "content:\(dataset):\(id):\(ordinal)"
        case .web(let url):
            return "web:\(url)"
        case .derived(let id):
            return "derived:\(id)"
        }
    }

    var destination: AppDestination? {
        switch self {
        case .entity(let type, let id):
            return .entity(type: type, id: id)
        case .recipe(let id):
            return .recipe(id: id)
        case .content(let dataset, let id, let ordinal):
            return .content(dataset: dataset, id: id, sourceOrdinal: ordinal)
        case .web, .derived:
            return nil
        }
    }
}

enum EvidencePayload: Hashable, Sendable {
    case entity(Entity)
    case recipe(Recipe)
    case content(ContentRecord)
    case web(WebHit)
    case derived(DerivedEvidence)

    var card: AtlasCard? {
        switch self {
        case .entity(let entity): return .entity(entity)
        case .recipe(let recipe): return .recipe(recipe)
        case .content(let record): return .content(record)
        case .web(let hit): return .web(hit)
        case .derived: return nil
        }
    }

    var canonicalDigestSource: String {
        switch self {
        case .entity(let entity):
            return [
                entity.entityType,
                entity.gameID,
                entity.title,
                entity.subtitle ?? "",
                entity.description ?? "",
                entity.sourceCommitSHA,
            ].joined(separator: "\u{1e}")
        case .recipe(let recipe):
            let ingredients = recipe.ingredients
                .map { "\($0.position):\($0.entityType):\($0.gameID):\($0.amount ?? "")" }
                .joined(separator: ",")
            return [
                recipe.recipeID,
                recipe.recipeKind,
                recipe.outputEntityType,
                recipe.outputGameID,
                recipe.outputAmount ?? "",
                recipe.sourceCommitSHA,
                ingredients,
            ].joined(separator: "\u{1e}")
        case .content(let record):
            return [
                record.dataset,
                record.externalID,
                String(record.sourceOrdinal),
                record.title,
                record.sourceCommitSHA,
            ].joined(separator: "\u{1e}")
        case .web(let hit):
            return [hit.url.absoluteString, hit.title, hit.snippet].joined(separator: "\u{1e}")
        case .derived(let derived):
            return derived.digest
        }
    }
}

struct DerivedEvidence: Hashable, Sendable, Equatable {
    var engineName: String
    var engineVersion: String
    var normalizedInputs: [String: String]
    var bounds: [String: String]
    var parentEvidenceIDs: [String]
    var packReleaseID: String
    var output: String
    var digest: String

    var provenanceLabel: String {
        "Calculated from pack \(String(packReleaseID.prefix(12)))"
    }

    static func make(
        engineName: String,
        engineVersion: String,
        normalizedInputs: [String: String],
        bounds: [String: String] = RecipeExpansionBounds.current.asDictionary,
        parentEvidenceIDs: [String],
        packReleaseID: String,
        output: String
    ) -> DerivedEvidence {
        let digest = EvidenceDigest.hex(
            [
                engineName,
                engineVersion,
                canonicalMap(normalizedInputs),
                canonicalMap(bounds),
                parentEvidenceIDs.joined(separator: ","),
                packReleaseID,
                output,
            ].joined(separator: "\u{1e}")
        )
        return DerivedEvidence(
            engineName: engineName,
            engineVersion: engineVersion,
            normalizedInputs: normalizedInputs,
            bounds: bounds,
            parentEvidenceIDs: parentEvidenceIDs,
            packReleaseID: packReleaseID,
            output: output,
            digest: digest
        )
    }

    private static func canonicalMap(_ values: [String: String]) -> String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "&")
    }
}

struct EvidenceRecord: Hashable, Sendable, Equatable {
    var evidenceID: String
    var snapshotID: String
    var recordKey: RecordKey
    var source: EvidenceSourceKind
    var packReleaseID: String
    var sourceCommitSHA: String
    var payloadDigest: String
    var payload: EvidencePayload

    var isCalculated: Bool {
        if case .derived = payload { return true }
        return source == .calculated
    }
}

struct EvidenceBundle: Sendable, Equatable {
    var turnID: String
    var snapshotID: String
    var packReleaseID: String
    var sourceCommitSHA: String
    var records: [EvidenceRecord]

    var evidenceIDs: [String] { records.map(\.evidenceID) }

    var digest: String {
        EvidenceDigest.hex(evidenceIDs.joined(separator: ","))
    }

    func record(id: String) -> EvidenceRecord? {
        records.first { $0.evidenceID == id }
    }
}

enum EvidenceError: Error, Equatable, LocalizedError, Sendable {
    case unknownID(String)
    case staleID(String)
    case packMismatch
    case invalidAncestry(String)

    var errorDescription: String? {
        switch self {
        case .unknownID:
            return "The evidence ID is not in the current ledger."
        case .staleID:
            return "The evidence ID belongs to a previous snapshot."
        case .packMismatch:
            return "The evidence belongs to a different pack release."
        case .invalidAncestry:
            return "Derived evidence parents are missing or stale."
        }
    }
}

enum EvidenceDigest {
    static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class EvidenceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotID: String
    private var packReleaseID: String
    private var sourceCommitSHA: String
    private var records: [String: EvidenceRecord] = [:]
    private var retainedIDs: Set<String> = []

    init(packIdentity: PackIdentity, snapshotID: String = UUID().uuidString) {
        self.snapshotID = snapshotID
        self.packReleaseID = packIdentity.sourceCommitSHA
        self.sourceCommitSHA = packIdentity.sourceCommitSHA
    }

    var currentSnapshotID: String {
        lock.lock()
        defer { lock.unlock() }
        return snapshotID
    }

    var currentPackReleaseID: String {
        lock.lock()
        defer { lock.unlock() }
        return packReleaseID
    }

    func reset(packIdentity: PackIdentity) {
        lock.lock()
        defer { lock.unlock() }
        snapshotID = UUID().uuidString
        packReleaseID = packIdentity.sourceCommitSHA
        sourceCommitSHA = packIdentity.sourceCommitSHA
        retainedIDs.removeAll()
    }

    @discardableResult
    func issue(
        payload: EvidencePayload,
        source: EvidenceSourceKind,
        packReleaseID: String? = nil
    ) -> EvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        let release = packReleaseID ?? self.packReleaseID
        let key = Self.recordKey(for: payload)
        let payloadDigest = EvidenceDigest.hex(payload.canonicalDigestSource)
        let evidenceID = EvidenceDigest.hex(
            [source.rawValue, key.canonical, payloadDigest, release, snapshotID].joined(separator: "|")
        )
        if let existing = records[evidenceID] {
            return existing
        }
        let sha: String
        switch payload {
        case .entity(let entity): sha = entity.sourceCommitSHA
        case .recipe(let recipe): sha = recipe.sourceCommitSHA
        case .content(let record): sha = record.sourceCommitSHA
        case .web: sha = "community-web"
        case .derived: sha = release
        }
        let record = EvidenceRecord(
            evidenceID: evidenceID,
            snapshotID: snapshotID,
            recordKey: key,
            source: source,
            packReleaseID: release,
            sourceCommitSHA: sha,
            payloadDigest: payloadDigest,
            payload: payload
        )
        records[evidenceID] = record
        return record
    }

    func retain(_ evidenceID: String) throws {
        _ = try resolve(evidenceID)
        lock.lock()
        retainedIDs.insert(evidenceID)
        lock.unlock()
    }

    func resolve(_ evidenceID: String) throws -> EvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let record = records[evidenceID] else {
            throw EvidenceError.unknownID(evidenceID)
        }
        guard record.snapshotID == snapshotID else {
            throw EvidenceError.staleID(evidenceID)
        }
        guard record.packReleaseID == packReleaseID else {
            throw EvidenceError.packMismatch
        }
        return record
    }

    func resolveMany(_ ids: [String]) throws -> [EvidenceRecord] {
        try ids.map { try resolve($0) }
    }

    func bundle(turnID: String, ids: [String]? = nil) -> EvidenceBundle {
        lock.lock()
        defer { lock.unlock() }
        let selected: [EvidenceRecord]
        if let ids {
            selected = ids.compactMap { records[$0] }
        } else {
            selected = Array(records.values)
        }
        return EvidenceBundle(
            turnID: turnID,
            snapshotID: snapshotID,
            packReleaseID: packReleaseID,
            sourceCommitSHA: sourceCommitSHA,
            records: selected.sorted { $0.evidenceID < $1.evidenceID }
        )
    }

    func validateDerivedAncestry(_ derived: DerivedEvidence) throws {
        for parent in derived.parentEvidenceIDs {
            _ = try resolve(parent)
        }
        guard derived.packReleaseID == currentPackReleaseID else {
            throw EvidenceError.packMismatch
        }
    }

    private static func recordKey(for payload: EvidencePayload) -> RecordKey {
        switch payload {
        case .entity(let entity):
            return .entity(type: entity.entityType, id: entity.gameID)
        case .recipe(let recipe):
            return .recipe(id: recipe.recipeID)
        case .content(let record):
            return .content(
                dataset: record.dataset,
                id: record.externalID,
                sourceOrdinal: record.sourceOrdinal
            )
        case .web(let hit):
            return .web(url: hit.url.absoluteString)
        case .derived(let derived):
            return .derived(id: derived.digest)
        }
    }
}

extension RecipeExpansionBounds {
    var asDictionary: [String: String] {
        [
            "depth": String(depth),
            "alternativesPerNode": String(alternativesPerNode),
            "maxVisitedNodes": String(maxVisitedNodes),
            "budgetMilliseconds": String(budgetMilliseconds),
        ]
    }
}
