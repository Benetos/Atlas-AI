import Foundation
import SwiftUI

enum PackStatus: Equatable {
    case locating
    case downloading(Double?)
    case verifying
    case activating
    case ready
    case missing(String)
}

@Observable
@MainActor
final class AppModel {
    var packStatus: PackStatus = .locating
    var store: SQLiteNMSStore?
    var catalog: (any NMSCatalog)?
    var pack: PackManifest?
    var packIdentity: PackIdentity?
    var generationID: UInt64 = 0
    var settings: AppSettings
    var saved: SavedStore
    var liveRevision: String?
    var liveRevisionError: String?
    var packRole: String?
    var packRecoveryMessage: String?
    var packUpdateMessage: String?
    var packUpdateProgress: Double?
    var isPackUpdateRunning = false

    let services: AppServices
    private var activationStore: PackActivationStore?

    init(services: AppServices = .live) {
        self.services = services
        self.settings = AppSettings(defaults: services.userDefaults)
        self.saved = SavedStore(
            artifacts: SavedArtifactsStore(
                directory: services.savedDirectory,
                clock: services.clock
            ),
            defaults: services.userDefaults
        )
        self.catalog = services.catalog
        self.packIdentity = services.packIdentity
        if services.catalog != nil {
            packStatus = .ready
        }
    }

    func bootstrap() async {
        await saved.bootstrap()
        if services.catalog != nil {
            packStatus = .ready
            return
        }
        guard !isPackUpdateRunning else { return }
        isPackUpdateRunning = true
        packStatus = .locating
        do {
            #if DEBUG
            // Normal development and hosted integration tests run against the
            // complete generated pack. The small disposable fixture belongs to
            // AtlasTests only and must never masquerade as the app's catalog.
            let bundled = try PackValidator(requiredRole: "production").validate(
                PackLocator.bundledDebugPack()
            )
            try open(bundled)
            packStatus = .ready
            packUpdateMessage = "Using the full pinned Debug database."
            isPackUpdateRunning = false
            #else
            let activation = try makeActivationStore()
            if let installed = try await activation.current() {
                try open(installed)
                packStatus = .ready
                isPackUpdateRunning = false
                await refreshPack()
                return
            }
            isPackUpdateRunning = false
            await refreshPack(requireLatestVersion: false)
            #endif
        } catch {
            packStatus = .missing(error.localizedDescription)
            packUpdateMessage = error.localizedDescription
            isPackUpdateRunning = false
        }
    }

    func refreshPack(requireLatestVersion: Bool = true) async {
        guard !isPackUpdateRunning else { return }
        isPackUpdateRunning = true
        packUpdateMessage = "Checking the on-device database…"
        packUpdateProgress = nil
        do {
            let activation = try makeActivationStore()
            let candidate = try await ManagedPackProvider().candidate(
                requireLatestVersion: requireLatestVersion
            ) { [weak self] progress in
                self?.apply(progress)
            }
            let installed = try await activation.activate(candidate) { [weak self] progress in
                self?.apply(progress)
            }
            try open(installed)
            packStatus = .ready
            packUpdateMessage = "The on-device database is up to date."
            packUpdateProgress = 1
        } catch {
            packUpdateMessage = error.localizedDescription
            packUpdateProgress = nil
            if store == nil {
                packStatus = .missing(error.localizedDescription)
            } else {
                packStatus = .ready
            }
        }
        isPackUpdateRunning = false
    }

    private func makeActivationStore() throws -> PackActivationStore {
        if let activationStore { return activationStore }
        let created = PackActivationStore(rootURL: try PackLocator.activationRootURL())
        activationStore = created
        return created
    }

    private func open(_ verified: VerifiedPack) throws {
        let opened = try SQLiteNMSStore(fileURL: verified.sqliteURL)
        let manifest = try opened.manifest()
        store = opened
        catalog = SQLiteNMSCatalog(store: opened, packRole: verified.sidecar.packRole)
        pack = manifest
        packIdentity = PackIdentity(manifest: manifest, packRole: verified.sidecar.packRole)
        packRole = verified.sidecar.packRole
        packRecoveryMessage = verified.recoveredFromRollback
            ? "Atlas recovered the previous verified database after the active copy failed validation."
            : nil
        generationID += 1
    }

    private func apply(_ progress: ManagedPackProgress) {
        switch progress {
        case .checking:
            packUpdateMessage = "Checking the on-device database…"
            packUpdateProgress = nil
            if store == nil { packStatus = .locating }
        case .downloading(let fraction):
            packUpdateMessage = "Downloading the on-device database…"
            packUpdateProgress = fraction
            if store == nil { packStatus = .downloading(fraction) }
        case .verifying:
            packUpdateMessage = "Verifying the on-device database…"
            packUpdateProgress = nil
            if store == nil { packStatus = .verifying }
        case .activating:
            packUpdateMessage = "Activating the on-device database…"
            packUpdateProgress = nil
            if store == nil { packStatus = .activating }
        }
    }

    func refreshLiveRevision() async {
        guard settings.liveAtlasEnabled else {
            liveRevision = nil
            liveRevisionError = nil
            return
        }
        services.network.record("liveAtlas.sourceCommitSHA")
        do {
            liveRevision = try await LiveAtlasClient(settings: settings).sourceCommitSHA()
            liveRevisionError = nil
        } catch {
            liveRevision = nil
            liveRevisionError = error.localizedDescription
        }
    }

    func bookmark(for entity: Entity) -> SavedItem {
        .entity(entity, savedAt: services.clock.now(), packReleaseID: packIdentity?.sourceCommitSHA)
    }

    func bookmark(for recipe: Recipe) -> SavedItem {
        .recipe(recipe, savedAt: services.clock.now(), packReleaseID: packIdentity?.sourceCommitSHA)
    }
}
