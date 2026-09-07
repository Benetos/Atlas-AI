import CryptoKit
import Foundation

actor SavedArtifactsStore {
    static let currentSchemaVersion = 1
    static let bookmarksDefaultsKey = "atlas.savedItems"
    static let recentsDefaultsKey = "atlas.recentItems"

    private let directory: URL
    private let clock: any Clock
    private let fileManager: FileManager

    init(directory: URL, clock: any Clock, fileManager: FileManager = .default) {
        self.directory = directory
        self.clock = clock
        self.fileManager = fileManager
    }

    func snapshot() throws -> SavedArtifactsSnapshot {
        let document = try loadDocument()
        return snapshot(from: document)
    }

    func upsertBookmark(_ item: SavedItem) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        let now = clock.now()
        let existing = document.records.first { $0.id == item.id }
        let record = SavedArtifactRecord.bookmark(from: item, existing: existing, now: now)
        document.records.removeAll { $0.id == item.id }
        document.records.insert(record, at: 0)
        try persist(document)
        return try snapshot()
    }

    func removeBookmark(id: String) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        document.records.removeAll { $0.id == id && $0.kind == SavedArtifactKind.bookmark.rawValue }
        try persist(document)
        return try snapshot()
    }

    func upsertRecipePlan(_ plan: SavedRecipePlan) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        let now = clock.now()
        let existing = document.records.first { $0.id == plan.id }
        let record = try SavedArtifactRecord.recipePlan(from: plan, existing: existing, now: now)
        document.records.removeAll { $0.id == plan.id }
        document.records.insert(record, at: 0)
        try persist(document)
        return try snapshot()
    }

    func removeRecipePlan(id: String) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        document.records.removeAll { $0.id == id && $0.kind == SavedArtifactKind.recipePlan.rawValue }
        try persist(document)
        return try snapshot()
    }

    func rememberRecent(_ item: SavedItem) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        let now = clock.now()
        let existing = document.recents.first { $0.id == item.id }
        let record = SavedArtifactRecord.bookmark(from: item, existing: existing, now: now)
        document.recents.removeAll { $0.id == item.id }
        document.recents.insert(record, at: 0)
        if document.recents.count > 30 {
            document.recents = Array(document.recents.prefix(30))
        }
        try persist(document)
        return try snapshot()
    }

    func clearRecents() throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        document.recents = []
        try persist(document)
        return try snapshot()
    }

    func migrateLegacyBookmarksIfNeeded(defaults: UserDefaults) throws -> SavedArtifactsSnapshot {
        var document = try loadDocument()
        if document.legacyBookmarkMigrationCompleted {
            return snapshot(from: document)
        }

        let legacyBookmarks = Self.decodeLegacyItems(defaults.data(forKey: Self.bookmarksDefaultsKey))
        let legacyRecents = Self.decodeLegacyItems(defaults.data(forKey: Self.recentsDefaultsKey))
        if case .invalid = legacyBookmarks {
            return snapshot(from: document)
        }
        if case .invalid = legacyRecents {
            return snapshot(from: document)
        }
        let now = clock.now()

        for item in legacyBookmarks.items.reversed() {
            if document.records.contains(where: { $0.id == item.id }) { continue }
            document.records.insert(
                SavedArtifactRecord.bookmark(from: item, existing: nil, now: now),
                at: 0
            )
        }
        for item in legacyRecents.items.reversed() {
            if document.recents.contains(where: { $0.id == item.id }) { continue }
            document.recents.insert(
                SavedArtifactRecord.bookmark(from: item, existing: nil, now: now),
                at: 0
            )
        }
        if document.recents.count > 30 {
            document.recents = Array(document.recents.prefix(30))
        }
        document.legacyBookmarkMigrationCompleted = true
        try persist(document)
        let reopened = try loadDocument()
        guard reopened.legacyBookmarkMigrationCompleted else {
            throw CatalogError.failure("Saved artifact migration could not be verified.")
        }
        return snapshot(from: reopened)
    }

    private struct Document {
        var storeSchemaVersion: Int
        var legacyBookmarkMigrationCompleted: Bool
        var records: [SavedArtifactRecord]
        var recents: [SavedArtifactRecord]
    }

    private var currentURL: URL {
        directory.appendingPathComponent("saved-artifacts.json")
    }

    private var previousURL: URL {
        directory.appendingPathComponent("saved-artifacts.previous.json")
    }

    private var temporaryURL: URL {
        directory.appendingPathComponent("saved-artifacts.json.tmp")
    }

    private var quarantineDirectory: URL {
        directory.appendingPathComponent("quarantine", isDirectory: true)
    }

    private func snapshot(from document: Document) -> SavedArtifactsSnapshot {
        SavedArtifactsSnapshot(
            bookmarks: document.records.compactMap { $0.bookmark() },
            recents: document.recents.compactMap { $0.bookmark() },
            recipePlans: document.records.compactMap { $0.recipePlan() },
            records: document.records
        )
    }

    private func persist(_ document: Document) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encode(document)
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: currentURL.path) {
            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
            try fileManager.copyItem(at: currentURL, to: previousURL)
            _ = try fileManager.replaceItemAt(currentURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: currentURL)
        }
    }

    private func loadDocument() throws -> Document {
        if let current = openVerified(currentURL) {
            return current
        }
        if fileManager.fileExists(atPath: currentURL.path) {
            try quarantine(currentURL)
        }
        if let previous = openVerified(previousURL) {
            try persist(previous)
            return previous
        }
        return Document(
            storeSchemaVersion: Self.currentSchemaVersion,
            legacyBookmarkMigrationCompleted: false,
            records: [],
            recents: []
        )
    }

    private func openVerified(_ url: URL) -> Document? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decode(object)
    }

    private func quarantine(_ url: URL) throws {
        try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let name = "saved-artifacts-\(formatter.string(from: clock.now())).json"
            .replacingOccurrences(of: ":", with: "-")
        let destination = quarantineDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: url, to: destination)
    }

    private func encode(_ document: Document) throws -> Data {
        var object: [String: Any] = [
            "storeSchemaVersion": document.storeSchemaVersion,
            "legacyBookmarkMigrationCompleted": document.legacyBookmarkMigrationCompleted,
            "bookmarks": document.records.map(recordJSON),
            "recents": document.recents.map(recordJSON),
        ]
        let canonical = try canonicalJSON(object)
        object["checksum"] = sha256(canonical)
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func decode(_ object: [String: Any]) -> Document? {
        guard let version = object["storeSchemaVersion"] as? Int,
              version == Self.currentSchemaVersion,
              let checksum = object["checksum"] as? String
        else { return nil }
        var body = object
        body.removeValue(forKey: "checksum")
        guard let canonical = try? canonicalJSON(body), sha256(canonical) == checksum else {
            return nil
        }
        let bookmarks = decodeRecords(object["bookmarks"])
        let recents = decodeRecords(object["recents"])
        return Document(
            storeSchemaVersion: version,
            legacyBookmarkMigrationCompleted: object["legacyBookmarkMigrationCompleted"] as? Bool ?? false,
            records: bookmarks,
            recents: recents
        )
    }

    private func decodeRecords(_ value: Any?) -> [SavedArtifactRecord] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let kind = row["kind"] as? String,
                  let payloadVersion = row["payloadVersion"] as? Int,
                  let createdAt = decodeDate(row["createdAt"]),
                  let updatedAt = decodeDate(row["updatedAt"]),
                  let payload = row["payload"] as? [String: Any]
            else { return nil }
            return SavedArtifactRecord(
                id: id,
                kind: kind,
                payloadVersion: payloadVersion,
                createdAt: createdAt,
                updatedAt: updatedAt,
                originatingPackReleaseID: row["originatingPackReleaseID"] as? String,
                originatingCapabilities: row["originatingCapabilities"] as? [String] ?? [],
                payload: payload
            )
        }
    }

    private func recordJSON(_ record: SavedArtifactRecord) -> [String: Any] {
        var object: [String: Any] = [
            "id": record.id,
            "kind": record.kind,
            "payloadVersion": record.payloadVersion,
            "createdAt": iso8601(record.createdAt),
            "updatedAt": iso8601(record.updatedAt),
            "originatingCapabilities": record.originatingCapabilities,
            "payload": record.payload,
        ]
        if let pack = record.originatingPackReleaseID {
            object["originatingPackReleaseID"] = pack
        }
        return object
    }

    private func canonicalJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func iso8601(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func decodeDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return Self.dateFormatter.date(from: raw)
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private enum LegacyDecodeResult {
        case missing
        case items([SavedItem])
        case invalid

        var items: [SavedItem] {
            if case .items(let items) = self { return items }
            return []
        }
    }

    private static func decodeLegacyItems(_ data: Data?) -> LegacyDecodeResult {
        guard let data else { return .missing }
        struct LegacyItem: Codable {
            var kind: SavedItem.Kind
            var entityType: String?
            var gameID: String?
            var recipeID: String?
            var title: String
            var savedAt: Date
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let items = try? decoder.decode([LegacyItem].self, from: data) else {
            return .invalid
        }
        return .items(items.map {
            SavedItem(
                kind: $0.kind,
                entityType: $0.entityType,
                gameID: $0.gameID,
                recipeID: $0.recipeID,
                title: $0.title,
                savedAt: $0.savedAt,
                originatingPackReleaseID: nil
            )
        })
    }
}
