import Foundation
import SwiftUI

enum PackStatus: Equatable {
    case locating
    case ready
    case missing(String)
}

@Observable
final class AppModel {
    var packStatus: PackStatus = .locating
    var store: SQLiteNMSStore?
    var pack: PackManifest?
    var settings = AppSettings()
    var saved = SavedStore()
    var path = NavigationPath()
    var liveRevision: String?
    var liveRevisionError: String?

    func bootstrap() async {
        packStatus = .locating
        do {
            let url = try PackLocator.locateSQLite()
            let opened = try SQLiteNMSStore(fileURL: url)
            store = opened
            pack = try opened.manifest()
            packStatus = .ready
        } catch {
            packStatus = .missing(error.localizedDescription)
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
}
