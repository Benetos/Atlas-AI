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
    var pack: PackManifest?
    var settings = AppSettings()
    var saved = SavedStore()
    var path = NavigationPath()
    var liveRevision: String?
    var liveRevisionError: String?
    var packRole: String?
    var packRecoveryMessage: String?
    var packUpdateMessage: String?
    var packUpdateProgress: Double?
    var isPackUpdateRunning = false

    private var activationStore: PackActivationStore?

    func bootstrap() async {
        guard !isPackUpdateRunning else { return }
        isPackUpdateRunning = true
        packStatus = .locating
        do {
            let activation = try makeActivationStore()
            if let installed = try await activation.current() {
                try open(installed)
                packStatus = .ready
                isPackUpdateRunning = false
                await refreshPack()
                return
            }

            #if DEBUG
            let preview = try PackValidator(requiredRole: "preview").validate(
                PackLocator.bundledPreview()
            )
            try open(preview)
            packStatus = .ready
            packUpdateMessage = "Using the Debug preview database."
            isPackUpdateRunning = false
            #else
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
        pack = manifest
        packRole = verified.sidecar.packRole
        packRecoveryMessage = verified.recoveredFromRollback
            ? "Atlas recovered the previous verified database after the active copy failed validation."
            : nil
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
        do {
            liveRevision = try await LiveAtlasClient(settings: settings).sourceCommitSHA()
            liveRevisionError = nil
        } catch {
            liveRevision = nil
            liveRevisionError = error.localizedDescription
        }
    }
}

enum AtlasRoute: Hashable {
    case entity(type: String, id: String)
    case recipe(id: String)
    case content(dataset: String, id: String, sourceOrdinal: Int)
}
