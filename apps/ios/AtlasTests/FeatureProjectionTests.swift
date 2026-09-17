import XCTest
@testable import Atlas

final class FeatureProjectionTests: XCTestCase {
    func testPreviewPackProjectsFishAndBaitFacts() throws {
        let store = try SQLiteNMSStore(fileURL: fixtureURL())
        let manifest = try store.manifest()
        XCTAssertEqual(manifest.packSchemaVersion, 2)

        let fish = try XCTUnwrap(
            try store.specialistRecord(feature: .fish, id: "F_JELLYCHILD", sourceOrdinal: 0)
        )
        XCTAssertEqual(fish.summary.title, "Child of Aquarius")
        XCTAssertEqual(fish.fields.first { $0.key == "time_of_day" }?.value, "Night")
        XCTAssertEqual(fish.fields.first { $0.key == "needs_storm" }?.value, "true")
        XCTAssertEqual(fish.biomes, ["Frozen", "Lush"])
        XCTAssertEqual(fish.extraFields.first { $0.key == "Mystery" }?.value, "keep-me")
        XCTAssertEqual(
            fish.summary.iconSourcePath,
            "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS"
        )

        let nightFish = try store.specialistSummaries(
            SpecialistQuery(feature: .fish, timeOfDay: "Night", limit: 20)
        )
        XCTAssertTrue(nightFish.contains { $0.externalID == "F_JELLYCHILD" })

        let bait = try XCTUnwrap(
            try store.specialistRecord(feature: .bait, id: "NANOTUBES", sourceOrdinal: 0)
        )
        XCTAssertEqual(bait.summary.title, "Carbon Nanotubes")
        XCTAssertEqual(bait.fields.first { $0.key == "used_for" }?.value, "Night")
        XCTAssertEqual(bait.fields.first { $0.key == "rarity_percent" }?.value, "6")
        XCTAssertEqual(bait.fields.first { $0.key == "size_percent" }?.value, "2")
        XCTAssertFalse(bait.fields.contains { $0.label.lowercased().contains("species") })

        let nightBait = try store.specialistSummaries(
            SpecialistQuery(feature: .bait, usedFor: "Night", limit: 20)
        )
        XCTAssertEqual(nightBait.map(\.externalID), ["NANOTUBES"])
        XCTAssertNil(SpecialistFeature(dataset: "expeditions"))
        XCTAssertEqual(SpecialistFeature(dataset: "fish"), .fish)

        XCTAssertEqual(fish.extraFields.first { $0.key == "Colour_R" }?.value, "0.2")
        XCTAssertEqual(fish.extraFields.first { $0.key == "MissionMustAlsoBeSelected" }?.value, "true")

        let fishOptions = try store.specialistFilterOptions(feature: .fish)
        XCTAssertEqual(Set(fishOptions.times), ["Night"])
        XCTAssertFalse(fishOptions.times.contains(PackedFishMembership.anyTime))
        XCTAssertEqual(Set(fishOptions.biomes), ["Frozen", "Lush"])
        XCTAssertFalse(fishOptions.biomes.contains(PackedFishMembership.anyBiome))

        let nightFrozen = try store.specialistSummaries(
            SpecialistQuery(feature: .fish, timeOfDay: "Night", biome: "Frozen", limit: 20)
        )
        XCTAssertTrue(nightFrozen.contains { $0.externalID == "F_JELLYCHILD" })
        XCTAssertTrue(nightFrozen.contains { $0.externalID == "F_BOTHFISH" })

        let dayFish = try store.specialistSummaries(
            SpecialistQuery(feature: .fish, timeOfDay: "Day", limit: 20)
        )
        XCTAssertTrue(dayFish.contains { $0.externalID == "F_BOTHFISH" })
        XCTAssertFalse(dayFish.contains { $0.externalID == "F_JELLYCHILD" })
        XCTAssertTrue(PackedFishMembership.matchesTime("Both", selected: "Night"))
        XCTAssertTrue(PackedFishMembership.matchesBiome("All", selected: "Frozen"))
        XCTAssertFalse(PackedFishMembership.matchesTime("Night", selected: "Day"))

        let noStorm = try store.specialistSummaries(
            SpecialistQuery(feature: .fish, needsStorm: false, limit: 20)
        )
        XCTAssertTrue(noStorm.contains { $0.externalID == "F_BOTHFISH" })
        XCTAssertFalse(noStorm.contains { $0.externalID == "F_JELLYCHILD" })

        let hidden = try store.specialistSummaries(
            SpecialistQuery(feature: .buildingParts, includeNotEnabled: false, limit: 20)
        )
        XCTAssertEqual(hidden.map(\.externalID), ["PART_CORE"])
        XCTAssertFalse(
            try store.specialistFilterOptions(feature: .buildingParts).categories.contains("NotEnabled")
        )
        let shown = try store.specialistSummaries(
            SpecialistQuery(feature: .buildingParts, includeNotEnabled: true, limit: 20)
        )
        XCTAssertTrue(shown.contains { $0.externalID == "PART_HIDDEN" })

        let withFerrite = try store.specialistSummaries(
            SpecialistQuery(
                feature: .buildingParts,
                includeNotEnabled: false,
                requiredGameID: "FUEL1",
                limit: 20
            )
        )
        XCTAssertEqual(withFerrite.map(\.externalID), ["PART_CORE"])

        let part = try XCTUnwrap(
            try store.specialistRecord(feature: .buildingParts, id: "PART_CORE", sourceOrdinal: 0)
        )
        XCTAssertEqual(part.requirements.first?.gameID, "FUEL1")
        XCTAssertNil(part.requirements.first?.entityType)

        let story = try XCTUnwrap(
            try store.specialistRecord(feature: .stories, id: "STORY_GEK", sourceOrdinal: 0)
        )
        XCTAssertEqual(story.storyPages.first?.title, "Ancient Plaque")
        XCTAssertEqual(story.storyPages.first?.entries.first?.title, "First Spawn")
        XCTAssertEqual(story.storyPages.first?.entries.first?.body, "We are the masters of galaxies.")

        let legacy = try XCTUnwrap(
            try store.specialistRecord(feature: .legacyItems, id: "BAIT_MEAT_1", sourceOrdinal: 0)
        )
        XCTAssertEqual(legacy.fields.first { $0.key == "converts_to" }?.value, "BAIT_BASIC")
        XCTAssertEqual(legacy.fields.first { $0.key == "conversion_ratio" }?.value, "10")
        XCTAssertEqual(legacy.extraFields.first { $0.key == "ConvertName" }?.value, "Creature Pellets")

        let fossil = try XCTUnwrap(
            try store.specialistRecord(feature: .fossils, id: "FOSSIL_HEAD", sourceOrdinal: 0)
        )
        XCTAssertEqual(fossil.fields.first { $0.key == "category" }?.value, "Head")
        XCTAssertEqual(fossil.extraFields.first { $0.key == "Category" }?.value, "Special")

        let ship = try XCTUnwrap(
            try store.specialistRecord(feature: .shipParts, id: "FIGHTER_COCKPIT", sourceOrdinal: 0)
        )
        XCTAssertEqual(ship.extraFields.first { $0.key == "Description_Text" }?.value, "A packed fighter cockpit.")

        let reward = try XCTUnwrap(
            try store.specialistRecord(feature: .specialRewards, id: "REWARD_TWITCH", sourceOrdinal: 0)
        )
        XCTAssertEqual(reward.rewardSources, ["Twitch", "Expedition"])
    }

    func testPackedIconMapsSourceDDSPaths() {
        XCTAssertEqual(
            PackedIconLocator.relativePath(
                fromSourcePath: "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS"
            ),
            "icons/textures/ui/frontend/icons/fish/product2.fish.jelly.png"
        )
        XCTAssertNil(PackedIconLocator.relativePath(fromSourcePath: ""))
        XCTAssertNil(PackedIconLocator.relativePath(fromSourcePath: nil))
    }

    func testPackedIconFindsPresentFileAndIgnoresMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-icon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let relative = try XCTUnwrap(
            PackedIconLocator.relativePath(
                fromSourcePath: "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS"
            )
        )
        let present = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: present.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: present)

        XCTAssertEqual(
            PackedIconLocator.fileURL(
                sourcePath: "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS",
                packDirectory: directory
            )?.path,
            present.path
        )
        XCTAssertNil(
            PackedIconLocator.fileURL(
                sourcePath: "TEXTURES/MISSING.DDS",
                packDirectory: directory
            )
        )
    }

    func testContentDetailRoutesKnownDatasetsToSpecialistFeatures() {
        XCTAssertEqual(SpecialistFeature(dataset: "bait"), .bait)
        XCTAssertEqual(SpecialistFeature(dataset: "building_parts"), .buildingParts)
        XCTAssertEqual(SpecialistFeature(dataset: "ship_parts"), .shipParts)
        XCTAssertEqual(SpecialistFeature(dataset: "corvette_parts"), .corvetteParts)
        XCTAssertEqual(SpecialistFeature(dataset: "stories"), .stories)
        XCTAssertNil(SpecialistFeature(dataset: "expeditions"))
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "nms-reference", withExtension: "sqlite"),
            "The AtlasTests preview fixture is missing."
        )
    }
}
