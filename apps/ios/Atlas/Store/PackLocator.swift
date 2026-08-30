import Foundation

enum PackLocatorError: LocalizedError {
    case sqliteMissing

    var errorDescription: String? {
        switch self {
        case .sqliteMissing:
            return "The Atlas SQLite pack was not found in the app group container or the app bundle."
        }
    }
}

enum PackLocator {
    static let packID = "nms-reference"
    static let sqliteName = "nms-reference.sqlite"
    static let appGroupID = "group.ai.atlas.nms"

    /// Prefer a hosted/copied pack over the bundled Debug preview so Release
    /// builds that still contain `nms-reference.sqlite` in the target use the
    /// essential Background Asset when it is present.
    static func locateSQLite() throws -> URL {
        if let hosted = hostedSQLiteURL() {
            return hosted
        }
        if let bundled = Bundle.main.url(forResource: "nms-reference", withExtension: "sqlite") {
            return bundled
        }
        throw PackLocatorError.sqliteMissing
    }

    static func hostedSQLiteURL() -> URL? {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let hosted = group.appendingPathComponent(sqliteName)
            if FileManager.default.fileExists(atPath: hosted.path) {
                return hosted
            }
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        if let support {
            let candidate = support.appendingPathComponent(sqliteName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
