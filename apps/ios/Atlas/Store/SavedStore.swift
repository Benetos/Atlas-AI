import Foundation

struct SavedItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case entity
        case recipe
    }

    var kind: Kind
    var entityType: String?
    var gameID: String?
    var recipeID: String?
    var title: String
    var savedAt: Date

    var id: String {
        switch kind {
        case .entity:
            return "entity:\(entityType ?? ""):\(gameID ?? "")"
        case .recipe:
            return "recipe:\(recipeID ?? "")"
        }
    }
}

@Observable
final class SavedStore {
    private let defaultsKey = "atlas.savedItems"
    private(set) var items: [SavedItem]
    private(set) var recents: [SavedItem]

    init() {
        items = Self.load(key: "atlas.savedItems")
        recents = Self.load(key: "atlas.recentItems")
    }

    func isSaved(_ item: SavedItem) -> Bool {
        items.contains(where: { $0.id == item.id })
    }

    func toggle(_ item: SavedItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        } else {
            items.insert(item, at: 0)
        }
        Self.save(items, key: defaultsKey)
    }

    func remember(_ item: SavedItem) {
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        if recents.count > 30 {
            recents = Array(recents.prefix(30))
        }
        Self.save(recents, key: "atlas.recentItems")
    }

    func removeItems(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where items.indices.contains(index) {
            items.remove(at: index)
        }
        Self.save(items, key: defaultsKey)
    }

    func clearRecents() {
        recents.removeAll()
        Self.save(recents, key: "atlas.recentItems")
    }

    private static func load(key: String) -> [SavedItem] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedItem].self, from: data)) ?? []
    }

    private static func save(_ items: [SavedItem], key: String) {
        let data = try? JSONEncoder().encode(items)
        UserDefaults.standard.set(data, forKey: key)
    }
}
