import Foundation

enum PackLocatorError: LocalizedError {
    case sqliteMissing
    case sidecarMissing

    var errorDescription: String? {
        switch self {
        case .sqliteMissing:
            return "The Atlas database is not installed on this device."
        case .sidecarMissing:
            return "The Atlas database verification record is missing."
        }
    }
}

enum PackLocator {
    static let packID = "nms-reference"
    static let sqliteName = "nms-reference.sqlite"
    static let sidecarName = "pack-manifest.json"
    static let appGroupID = "group.ai.atlas.nms"

    /// Atlas owns activated copies of Apple-managed files. Background Assets
    /// URLs are process-scoped transport URLs and must never be persisted.
    static func activationRootURL(fileManager: FileManager = .default) throws -> URL {
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return group.appendingPathComponent("AtlasPacks", isDirectory: true)
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("AtlasPacks", isDirectory: true)
    }

    #if DEBUG
    static func bundledPreview() throws -> PackCandidate {
        guard let sqliteURL = Bundle.main.url(
            forResource: "nms-reference",
            withExtension: "sqlite"
        ) else {
            throw PackLocatorError.sqliteMissing
        }
        guard let sidecarURL = Bundle.main.url(
            forResource: "pack-manifest",
            withExtension: "json"
        ) else {
            throw PackLocatorError.sidecarMissing
        }
        return PackCandidate(sqliteURL: sqliteURL, sidecarURL: sidecarURL)
    }
    #endif
}
