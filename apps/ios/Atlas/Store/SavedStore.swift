import Foundation

@Observable
@MainActor
final class SavedStore {
    private let artifacts: SavedArtifactsStore
    private let defaults: UserDefaults
    private(set) var items: [SavedItem] = []
    private(set) var recents: [SavedItem] = []

    init(artifacts: SavedArtifactsStore, defaults: UserDefaults) {
        self.artifacts = artifacts
        self.defaults = defaults
    }

    func bootstrap() async {
        do {
            apply(try await artifacts.migrateLegacyBookmarksIfNeeded(defaults: defaults))
        } catch {
            apply(try? await artifacts.snapshot())
        }
    }

    func isSaved(_ item: SavedItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    func toggle(_ item: SavedItem) async {
        do {
            if isSaved(item) {
                apply(try await artifacts.removeBookmark(id: item.id))
            } else {
                apply(try await artifacts.upsertBookmark(item))
            }
        } catch {
            return
        }
    }

    func remember(_ item: SavedItem) async {
        do {
            apply(try await artifacts.rememberRecent(item))
        } catch {
            return
        }
    }

    func removeItems(at offsets: IndexSet) async {
        let ids = offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil }
        for id in ids {
            if let snapshot = try? await artifacts.removeBookmark(id: id) {
                apply(snapshot)
            }
        }
    }

    func clearRecents() async {
        do {
            apply(try await artifacts.clearRecents())
        } catch {
            return
        }
    }

    private func apply(_ snapshot: SavedArtifactsSnapshot?) {
        guard let snapshot else { return }
        items = snapshot.bookmarks
        recents = snapshot.recents
    }
}
