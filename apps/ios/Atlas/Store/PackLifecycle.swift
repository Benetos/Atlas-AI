import BackgroundAssets
import CryptoKit
import Foundation
import System

struct PackCandidate: Sendable {
    let sqliteURL: URL
    let sidecarURL: URL
}

struct PackSidecar: Codable, Equatable, Sendable {
    struct SQLiteArtifact: Codable, Equatable, Sendable {
        let file: String
        let bytes: Int
        let sha256: String
    }

    struct Validation: Codable, Equatable, Sendable {
        let passed: Bool
        let errors: [String]
    }

    let packSchemaVersion: Int
    let contractVersion: Int
    let assetPackID: String
    let packRole: String
    let sourceRepository: String
    let sourceCommitSHA: String
    let sourceCommittedAt: String?
    let generatedAt: String
    let counts: [String: Int]
    let sqlite: SQLiteArtifact
    let validation: Validation

    enum CodingKeys: String, CodingKey {
        case packSchemaVersion = "pack_schema_version"
        case contractVersion = "contract_version"
        case assetPackID = "asset_pack_id"
        case packRole = "pack_role"
        case sourceRepository = "source_repository"
        case sourceCommitSHA = "source_commit_sha"
        case sourceCommittedAt = "source_committed_at"
        case generatedAt = "generated_at"
        case counts
        case sqlite
        case validation
    }
}

enum PackValidationError: LocalizedError {
    case invalidSidecar(String)
    case unsupportedPack(String)
    case checksumMismatch
    case sizeMismatch
    case databaseMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidSidecar(let detail):
            return "The Atlas verification record is invalid: \(detail)"
        case .unsupportedPack(let detail):
            return "This Atlas database cannot be used: \(detail)"
        case .checksumMismatch:
            return "The Atlas database did not match its delivery record."
        case .sizeMismatch:
            return "The Atlas database was incomplete."
        case .databaseMismatch(let detail):
            return "The Atlas database contents did not match its delivery record: \(detail)"
        }
    }
}

struct VerifiedPack: Sendable {
    let sqliteURL: URL
    let sidecarURL: URL
    let sidecar: PackSidecar
    let recoveredFromRollback: Bool
}

struct PackValidator: Sendable {
    static let supportedPackSchemaVersion = 1
    static let supportedContractVersion = 1
    static let requiredCountKeys = Set([
        "entities",
        "localizations_preferred",
        "recipes",
        "recipe_ingredients",
        "content_records",
    ])

    let requiredRole: String

    func validate(_ candidate: PackCandidate) throws -> VerifiedPack {
        let fileManager = FileManager.default
        guard candidate.sqliteURL.isFileURL, candidate.sidecarURL.isFileURL else {
            throw PackValidationError.invalidSidecar("pack files must be local")
        }
        guard fileManager.fileExists(atPath: candidate.sqliteURL.path),
              fileManager.fileExists(atPath: candidate.sidecarURL.path) else {
            throw PackValidationError.invalidSidecar("one or more pack files are missing")
        }
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let sqliteValues = try candidate.sqliteURL.resourceValues(forKeys: resourceKeys)
        let sidecarValues = try candidate.sidecarURL.resourceValues(forKeys: resourceKeys)
        guard sqliteValues.isRegularFile == true,
              sidecarValues.isRegularFile == true,
              sqliteValues.isSymbolicLink != true,
              sidecarValues.isSymbolicLink != true else {
            throw PackValidationError.invalidSidecar("pack files must be regular files")
        }

        let sidecarData = try Data(contentsOf: candidate.sidecarURL, options: .mappedIfSafe)
        guard sidecarData.count <= 1_048_576 else {
            throw PackValidationError.invalidSidecar("record is unexpectedly large")
        }
        let sidecar: PackSidecar
        do {
            sidecar = try JSONDecoder().decode(PackSidecar.self, from: sidecarData)
        } catch {
            throw PackValidationError.invalidSidecar(error.localizedDescription)
        }

        guard sidecar.assetPackID == PackLocator.packID,
              sidecar.sqlite.file == PackLocator.sqliteName else {
            throw PackValidationError.unsupportedPack("asset identity is incorrect")
        }
        guard sidecar.packRole == requiredRole else {
            throw PackValidationError.unsupportedPack(
                "expected a \(requiredRole) pack, found \(sidecar.packRole)"
            )
        }
        guard sidecar.packSchemaVersion == Self.supportedPackSchemaVersion,
              sidecar.contractVersion == Self.supportedContractVersion else {
            throw PackValidationError.unsupportedPack("schema or contract version is unsupported")
        }
        guard sidecar.validation.passed, sidecar.validation.errors.isEmpty else {
            throw PackValidationError.invalidSidecar("publisher validation failed")
        }
        guard Self.isSHA256(sidecar.sqlite.sha256),
              Self.isSourceCommit(sidecar.sourceCommitSHA),
              !sidecar.sourceRepository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(sidecar.counts.keys) == Self.requiredCountKeys,
              sidecar.counts.values.allSatisfy({ $0 >= 0 }) else {
            throw PackValidationError.invalidSidecar("identity, provenance, or counts are malformed")
        }
        if let sourceCommittedAt = sidecar.sourceCommittedAt,
           !Self.isISO8601(sourceCommittedAt) {
            throw PackValidationError.invalidSidecar("source commit timestamp is malformed")
        }

        let attributes = try fileManager.attributesOfItem(atPath: candidate.sqliteURL.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue == sidecar.sqlite.bytes else {
            throw PackValidationError.sizeMismatch
        }
        guard try Self.sha256(candidate.sqliteURL) == sidecar.sqlite.sha256 else {
            throw PackValidationError.checksumMismatch
        }

        let store = try SQLiteNMSStore(fileURL: candidate.sqliteURL)
        try store.validateIntegrity()
        try store.validateReadOnlyBoundary()
        let manifest = try store.manifest()
        guard manifest.packSchemaVersion == sidecar.packSchemaVersion,
              manifest.contractVersion == sidecar.contractVersion,
              manifest.sourceRepository == sidecar.sourceRepository,
              manifest.sourceCommitSHA == sidecar.sourceCommitSHA,
              manifest.sourceCommittedAt == sidecar.sourceCommittedAt,
              manifest.generatedAt == sidecar.generatedAt else {
            throw PackValidationError.databaseMismatch("manifest provenance differs")
        }
        guard try store.databaseCounts() == sidecar.counts else {
            throw PackValidationError.databaseMismatch("row counts differ")
        }

        return VerifiedPack(
            sqliteURL: candidate.sqliteURL,
            sidecarURL: candidate.sidecarURL,
            sidecar: sidecar,
            recoveredFromRollback: false
        )
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isSourceCommit(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isISO8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}

private struct PackReleaseDescriptor: Codable, Equatable, Sendable {
    let releaseID: String
    let sqliteSHA256: String
    let sourceCommitSHA: String
    let activatedAt: String
}

private struct PackActivationState: Codable, Equatable, Sendable {
    let version: Int
    let active: PackReleaseDescriptor
    let previous: PackReleaseDescriptor?
}

actor PackActivationStore {
    private let rootURL: URL
    private let releasesURL: URL
    private let stagingURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let validator: PackValidator

    init(
        rootURL: URL,
        requiredRole: String = "production",
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.releasesURL = rootURL.appendingPathComponent("releases", isDirectory: true)
        self.stagingURL = rootURL.appendingPathComponent("staging", isDirectory: true)
        self.stateURL = rootURL.appendingPathComponent("state.json")
        self.fileManager = fileManager
        self.validator = PackValidator(requiredRole: requiredRole)
    }

    func current() throws -> VerifiedPack? {
        try prepareDirectories()
        if let state = try? readState() {
            if let active = try? verifiedRelease(state.active, recovered: false) {
                return active
            }
            if let previous = state.previous,
               let recovered = try? verifiedRelease(previous, recovered: true) {
                try writeState(
                    PackActivationState(version: 1, active: previous, previous: nil)
                )
                return recovered
            }
        }

        let recovered = try validReleaseDescriptors()
        guard let active = recovered.first else { return nil }
        let previous = recovered.dropFirst().first
        try writeState(PackActivationState(version: 1, active: active, previous: previous))
        return try verifiedRelease(active, recovered: true)
    }

    func activate(
        _ candidate: PackCandidate,
        progress: (@MainActor @Sendable (ManagedPackProgress) -> Void)? = nil
    ) async throws -> VerifiedPack {
        try prepareDirectories()
        let stagingRelease = stagingURL.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingRelease,
            withIntermediateDirectories: false
        )
        var stagingMoved = false
        defer {
            if !stagingMoved {
                try? fileManager.removeItem(at: stagingRelease)
            }
        }

        let stagedSQLite = stagingRelease.appendingPathComponent(PackLocator.sqliteName)
        let stagedSidecar = stagingRelease.appendingPathComponent(PackLocator.sidecarName)
        try fileManager.copyItem(at: candidate.sqliteURL, to: stagedSQLite)
        try fileManager.copyItem(at: candidate.sidecarURL, to: stagedSidecar)
        await progress?(.verifying)
        let staged = try validator.validate(
            PackCandidate(sqliteURL: stagedSQLite, sidecarURL: stagedSidecar)
        )

        await progress?(.activating)
        let releaseID = staged.sidecar.sqlite.sha256
        let releaseURL = releasesURL.appendingPathComponent(releaseID, isDirectory: true)
        let installation = try installStagedRelease(stagingRelease, at: releaseURL)
        stagingMoved = installation.moved
        let installed = installation.pack
        let descriptor = descriptor(for: installed.sidecar)
        let oldState = try? readState()
        let previous: PackReleaseDescriptor?
        if oldState?.active.releaseID == descriptor.releaseID {
            if let oldPrevious = oldState?.previous, isValidRelease(oldPrevious) {
                previous = oldPrevious
            } else {
                previous = nil
            }
        } else if let oldActive = oldState?.active,
                  isValidRelease(oldActive) {
            previous = oldActive
        } else if let oldPrevious = oldState?.previous,
                  isValidRelease(oldPrevious) {
            previous = oldPrevious
        } else {
            previous = nil
        }
        try writeState(PackActivationState(version: 1, active: descriptor, previous: previous))
        pruneReleases(keeping: Set([descriptor.releaseID, previous?.releaseID].compactMap { $0 }))
        return VerifiedPack(
            sqliteURL: installed.sqliteURL,
            sidecarURL: installed.sidecarURL,
            sidecar: installed.sidecar,
            recoveredFromRollback: false
        )
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: releasesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    private func candidate(at releaseURL: URL) -> PackCandidate {
        PackCandidate(
            sqliteURL: releaseURL.appendingPathComponent(PackLocator.sqliteName),
            sidecarURL: releaseURL.appendingPathComponent(PackLocator.sidecarName)
        )
    }

    /// Installs a verified staging directory at its content-addressed path.
    /// An existing release is reused only after full validation. If that copy
    /// is damaged, it remains quarantined until the replacement validates at
    /// the final path, and the activation pointer is updated only by the caller.
    private func installStagedRelease(
        _ stagingRelease: URL,
        at releaseURL: URL
    ) throws -> (pack: VerifiedPack, moved: Bool) {
        guard fileManager.fileExists(atPath: releaseURL.path) else {
            try fileManager.moveItem(at: stagingRelease, to: releaseURL)
            do {
                return (try validateContentAddressedRelease(at: releaseURL), true)
            } catch {
                try? fileManager.removeItem(at: releaseURL)
                throw error
            }
        }

        do {
            return (try validateContentAddressedRelease(at: releaseURL), false)
        } catch {
            let quarantineURL = stagingURL.appendingPathComponent(
                ".quarantine-\(releaseURL.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: releaseURL, to: quarantineURL)

            var replacementMoved = false
            do {
                try fileManager.moveItem(at: stagingRelease, to: releaseURL)
                replacementMoved = true
                let installed = try validateContentAddressedRelease(at: releaseURL)
                try? fileManager.removeItem(at: quarantineURL)
                return (installed, true)
            } catch {
                let replacementError = error
                if replacementMoved {
                    try? fileManager.removeItem(at: releaseURL)
                }
                if !fileManager.fileExists(atPath: releaseURL.path) {
                    try? fileManager.moveItem(at: quarantineURL, to: releaseURL)
                }
                throw replacementError
            }
        }
    }

    private func validateContentAddressedRelease(at releaseURL: URL) throws -> VerifiedPack {
        let verified = try validator.validate(candidate(at: releaseURL))
        guard verified.sidecar.sqlite.sha256 == releaseURL.lastPathComponent else {
            throw PackValidationError.databaseMismatch("release directory identity differs")
        }
        return verified
    }

    private func verifiedRelease(
        _ descriptor: PackReleaseDescriptor,
        recovered: Bool
    ) throws -> VerifiedPack {
        guard descriptor.releaseID == descriptor.sqliteSHA256,
              descriptor.releaseID.count == 64,
              descriptor.releaseID.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }),
              descriptor.sourceCommitSHA.count == 40,
              descriptor.sourceCommitSHA.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              }) else {
            throw PackValidationError.invalidSidecar("activation pointer is malformed")
        }
        let releaseURL = releasesURL.appendingPathComponent(
            descriptor.releaseID,
            isDirectory: true
        )
        let verified = try validator.validate(candidate(at: releaseURL))
        guard verified.sidecar.sqlite.sha256 == descriptor.sqliteSHA256,
              verified.sidecar.sourceCommitSHA == descriptor.sourceCommitSHA else {
            throw PackValidationError.databaseMismatch("activation pointer differs")
        }
        return VerifiedPack(
            sqliteURL: verified.sqliteURL,
            sidecarURL: verified.sidecarURL,
            sidecar: verified.sidecar,
            recoveredFromRollback: recovered
        )
    }

    private func isValidRelease(_ descriptor: PackReleaseDescriptor) -> Bool {
        do {
            _ = try verifiedRelease(descriptor, recovered: false)
            return true
        } catch {
            return false
        }
    }

    private func validReleaseDescriptors() throws -> [PackReleaseDescriptor] {
        let urls = try fileManager.contentsOfDirectory(
            at: releasesURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url -> (Date, PackReleaseDescriptor)? in
            guard let verified = try? validateContentAddressedRelease(at: url) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (date, descriptor(for: verified.sidecar))
        }
        .sorted { $0.0 > $1.0 }
        .map { $0.1 }
    }

    private func descriptor(for sidecar: PackSidecar) -> PackReleaseDescriptor {
        PackReleaseDescriptor(
            releaseID: sidecar.sqlite.sha256,
            sqliteSHA256: sidecar.sqlite.sha256,
            sourceCommitSHA: sidecar.sourceCommitSHA,
            activatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func readState() throws -> PackActivationState {
        let data = try Data(contentsOf: stateURL)
        let state = try JSONDecoder().decode(PackActivationState.self, from: data)
        guard state.version == 1 else {
            throw PackValidationError.unsupportedPack("activation-state version is unsupported")
        }
        return state
    }

    private func writeState(_ state: PackActivationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: [.atomic])
    }

    private func pruneReleases(keeping releaseIDs: Set<String>) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: releasesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where !releaseIDs.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum ManagedPackProgress: Sendable {
    case checking
    case downloading(Double?)
    case verifying
    case activating
}

enum ManagedPackProviderError: LocalizedError {
    case packNotFound
    case deliveredFileMissing(String)

    var errorDescription: String? {
        switch self {
        case .packNotFound:
            return "The Atlas database pack is not available from the App Store."
        case .deliveredFileMissing(let name):
            return "The downloaded Atlas pack did not contain \(name)."
        }
    }
}

@available(iOS 26.0, *)
struct ManagedPackProvider {
    func candidate(
        requireLatestVersion: Bool,
        progress: @escaping @MainActor @Sendable (ManagedPackProgress) -> Void
    ) async throws -> PackCandidate {
        let manager = AssetPackManager.shared
        await progress(.checking)
        let observation = Task {
            for await update in manager.statusUpdates(
                forAssetPackWithID: PackLocator.packID
            ) {
                switch update {
                case .began, .paused:
                    await progress(.downloading(nil))
                case .downloading(_, let value):
                    await progress(.downloading(value.fractionCompleted))
                case .finished:
                    await progress(.downloading(1))
                case .failed:
                    break
                @unknown default:
                    break
                }
            }
        }
        defer { observation.cancel() }

        if requireLatestVersion {
            if #available(iOS 26.4, *) {
                // `ensureLocalAvailability` below performs the update check.
            } else {
                _ = try await manager.checkForUpdates()
            }
        }

        // This iOS 26 API remains available on iOS 27. Keeping the call here
        // lets the project build with both the Xcode 26 and Xcode 27 SDKs.
        let pack = try await manager.assetPack(withID: PackLocator.packID)

        if #available(iOS 26.4, *) {
            try await manager.ensureLocalAvailability(
                of: pack,
                requireLatestVersion: requireLatestVersion
            )
        } else {
            try await manager.ensureLocalAvailability(of: pack)
        }

        let sqliteURL = try manager.url(for: FilePath(PackLocator.sqliteName))
        let sidecarURL = try manager.url(for: FilePath(PackLocator.sidecarName))
        guard FileManager.default.fileExists(atPath: sqliteURL.path) else {
            throw ManagedPackProviderError.deliveredFileMissing(PackLocator.sqliteName)
        }
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            throw ManagedPackProviderError.deliveredFileMissing(PackLocator.sidecarName)
        }
        return PackCandidate(sqliteURL: sqliteURL, sidecarURL: sidecarURL)
    }
}
