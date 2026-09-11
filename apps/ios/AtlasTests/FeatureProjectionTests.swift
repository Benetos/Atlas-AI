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
