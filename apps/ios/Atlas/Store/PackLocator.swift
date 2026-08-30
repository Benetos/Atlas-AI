import Foundation

enum PackLocatorError: LocalizedError {
    case sqliteMissing

    var errorDescription: String? {
        switch self {
        case .sqliteMissing:
            return "The Atlas SQLite pack was not found in the app bundle or the app group container."
        }
    }
}

enum PackLocator {
    static let packID = "nms-reference"
    static let sqliteName = "nms-reference.sqlite"
    static let appGroupID = "group.ai.atlas.nms"

    static func locateSQLite() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "nms-reference", withExtension: "sqlite") {
            return bundled
        }
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let hosted = group.appendingPathComponent(sqliteName)
            if FileManager.default.fileExists(atPath: hosted.path) {
                return hosted
            }
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let candidate = support.appendingPathComponent(sqliteName)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw PackLocatorError.sqliteMissing
    }
}
