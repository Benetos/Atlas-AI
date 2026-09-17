import Foundation

@MainActor
@Observable
final class SpecialistCollectionModel {
    var feature: SpecialistFeature
    var search = ""
    var timeOfDay: String?
    var biome: String?
    var size: String?
    var quality: String?
    var needsStorm: Bool?
    var usedFor: String?
    var shipType: String?
    var category: String?
    var includeNotEnabled = false
    var requiredEntityType: String?
    var requiredGameID: String?
    var options = SpecialistFilterOptions.empty
    var items: [SpecialistSummary] = []
    var offset = 0
    var hasMore = true
    var isLoading = false
    var error: String?
    var compareIDs: [String] = []
    var compareDetails: [SpecialistDetail] = []
    var showingCompare = false

    private var loadGeneration: UInt64 = 0
    private let pageSize = 60

    init(feature: SpecialistFeature, route: SpecialistRoute? = nil) {
        self.feature = feature
        includeNotEnabled = route?.includeNotEnabled ?? !feature.hidesDisabledByDefault
        if let route {
            search = route.search
            timeOfDay = route.timeOfDay
            biome = route.biome
            size = route.size
            quality = route.quality
            needsStorm = route.needsStorm
            usedFor = route.usedFor
            shipType = route.shipType
            category = route.category
            requiredEntityType = route.requiredEntityType
            requiredGameID = route.requiredGameID
        }
    }

    var query: SpecialistQuery {
        SpecialistQuery(
            feature: feature,
            search: search,
            timeOfDay: timeOfDay,
            biome: biome,
            size: size,
            quality: quality,
            needsStorm: needsStorm,
            usedFor: usedFor,
            shipType: shipType,
            category: category,
            includeNotEnabled: includeNotEnabled,
            requiredEntityType: requiredEntityType,
            requiredGameID: requiredGameID,
            limit: pageSize,
            offset: offset
        )
    }

    var filterTaskID: String {
        [
            feature.dataset,
            search,
            timeOfDay ?? "",
            biome ?? "",
            size ?? "",
            quality ?? "",
            needsStorm.map { $0 ? "1" : "0" } ?? "",
            usedFor ?? "",
            shipType ?? "",
            category ?? "",
            includeNotEnabled ? "1" : "0",
            requiredEntityType ?? "",
            requiredGameID ?? "",
        ].joined(separator: ":")
    }

    func load(catalog: any NMSCatalog, reset: Bool) async {
        if isLoading && !reset { return }
        loadGeneration += 1
        let token = loadGeneration
        isLoading = true
        defer { isLoading = false }
        if reset {
            items = []
            offset = 0
            hasMore = true
        }
        do {
            if reset {
                options = try await catalog.specialistFilterOptions(feature: feature)
            }
            let page = try await catalog.specialistSummaries(query)
            guard token == loadGeneration else { return }
            items.append(contentsOf: page)
            offset += page.count
            hasMore = page.count == pageSize
            error = nil
        } catch is CancellationError {
            return
        } catch {
            guard token == loadGeneration else { return }
            self.error = error.localizedDescription
        }
    }

    func toggleCompare(_ item: SpecialistSummary) {
        if let index = compareIDs.firstIndex(of: item.id) {
            compareIDs.remove(at: index)
        } else if compareIDs.count < 2 {
            compareIDs.append(item.id)
        } else {
            compareIDs[1] = item.id
        }
    }

    func isComparing(_ item: SpecialistSummary) -> Bool {
        compareIDs.contains(item.id)
    }

    func openCompare(catalog: any NMSCatalog) async {
        let selected = items.filter { compareIDs.contains($0.id) }
        guard selected.count == 2, feature.supportsCompare else { return }
        do {
            var loaded: [SpecialistDetail] = []
            for item in selected {
                if let detail = try await catalog.specialistRecord(
                    feature: item.feature,
                    id: item.externalID,
                    sourceOrdinal: item.sourceOrdinal
                ) {
                    loaded.append(detail)
                }
            }
            compareDetails = loaded
            showingCompare = loaded.count == 2
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class SpecialistDetailModel {
    var state: LoadState<SpecialistDetail> = .idle
    var checkedRequirementIDs: Set<Int> = []
    var checkedStoryIDs: Set<String> = []
    private var loadGeneration: UInt64 = 0

    func load(
        feature: SpecialistFeature,
        id: String,
        sourceOrdinal: Int,
        catalog: any NMSCatalog
    ) async {
        loadGeneration += 1
        let token = loadGeneration
        state = .loading
        do {
            guard let detail = try await catalog.specialistRecord(
                feature: feature,
                id: id,
                sourceOrdinal: sourceOrdinal
            ) else {
                guard token == loadGeneration else { return }
                state = .notFound
                return
            }
            guard token == loadGeneration else { return }
            state = .loaded(detail)
        } catch is CancellationError {
            return
        } catch let error as CatalogError {
            guard token == loadGeneration else { return }
            switch error {
            case .notFound:
                state = .notFound
            default:
                state = .failed(error.localizedDescription)
            }
        } catch {
            guard token == loadGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
