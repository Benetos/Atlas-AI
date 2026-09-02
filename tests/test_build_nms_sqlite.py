import csv
import hashlib
import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "build_nms_sqlite.py"
SPEC = importlib.util.spec_from_file_location("build_nms_sqlite", MODULE_PATH)
build_nms_sqlite = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(build_nms_sqlite)

COMMIT = "142d9ffd8078944722243398202f22cbef47cd02"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, str]]) -> None:
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def fixture_import_dir(root: Path) -> Path:
    import_dir = root / "nms-import"
    import_dir.mkdir()

    entities = [
        {
            "entity_type": "substance",
            "game_id": "FUEL1",
            "name_id": "UI_FUEL1_NAME",
            "name_lower_id": "UI_FUEL1_NAME_L",
            "subtitle_id": "UI_FUEL1_SUB",
            "description_id": "UI_FUEL1_DESC",
            "name": "FERRITE DUST",
            "display_name": "Ferrite Dust",
            "subtitle": "Silicate Powder",
            "description": "A common silicate. Used in crafting and refining.",
            "category": "Substance",
            "subcategory": "Silicate",
            "rarity": "Common",
            "legality": "",
            "base_value": "12",
            "icon_source_path": "TEXTURES/UI/FUEL1.DDS",
            "icon_storage_path": "",
            "color_r": "0.5",
            "color_g": "0.5",
            "color_b": "0.5",
            "color_a": "1",
            "attributes": '{"Id":"FUEL1"}',
            "source_dataset": "substances",
            "source_commit_sha": COMMIT,
        },
        {
            "entity_type": "product",
            "game_id": "CIRCUITBOARD",
            "name_id": "UI_CIRCUIT_NAME",
            "name_lower_id": "",
            "subtitle_id": "",
            "description_id": "UI_CIRCUIT_DESC",
            "name": "CIRCUIT BOARD",
            "display_name": "Circuit Board",
            "subtitle": "Crafted Component",
            "description": "A crafted technology component.",
            "category": "Product",
            "subcategory": "Component",
            "rarity": "Rare",
            "legality": "",
            "base_value": "916224",
            "icon_source_path": "",
            "icon_storage_path": "",
            "color_r": "",
            "color_g": "",
            "color_b": "",
            "color_a": "",
            "attributes": '{"Id":"CIRCUITBOARD"}',
            "source_dataset": "products",
            "source_commit_sha": COMMIT,
        },
        {
            "entity_type": "product",
            "game_id": "FOOD_COOKED",
            "name_id": "",
            "name_lower_id": "",
            "subtitle_id": "",
            "description_id": "",
            "name": "COOKED MEAT",
            "display_name": "Cooked Meat",
            "subtitle": "",
            "description": "A cooked food product.",
            "category": "Product",
            "subcategory": "Food",
            "rarity": "",
            "legality": "",
            "base_value": "1",
            "icon_source_path": "",
            "icon_storage_path": "",
            "color_r": "",
            "color_g": "",
            "color_b": "",
            "color_a": "",
            "attributes": "{}",
            "source_dataset": "products",
            "source_commit_sha": COMMIT,
        },
    ]
    write_csv(
        import_dir / "entities.csv",
        [
            "entity_type", "game_id", "name_id", "name_lower_id",
            "subtitle_id", "description_id", "name", "display_name",
            "subtitle", "description", "category", "subcategory", "rarity",
            "legality", "base_value", "icon_source_path", "icon_storage_path",
            "color_r", "color_g", "color_b", "color_a", "attributes",
            "source_dataset", "source_commit_sha",
        ],
        entities,
    )

    localizations = [
        {
            "localization_id": "UI_FUEL1_NAME",
            "locale": "en",
            "source_ordinal": "0",
            "value": "FERRITE DUST",
            "is_preferred": "false",
            "source_commit_sha": COMMIT,
        },
        {
            "localization_id": "UI_FUEL1_NAME",
            "locale": "en",
            "source_ordinal": "1",
            "value": "Ferrite Dust",
            "is_preferred": "true",
            "source_commit_sha": COMMIT,
        },
    ]
    write_csv(
        import_dir / "localizations.csv",
        [
            "localization_id", "locale", "source_ordinal", "value",
            "is_preferred", "source_commit_sha",
        ],
        localizations,
    )

    recipes = [
        {
            "recipe_id": "crafting:product:CIRCUITBOARD:0",
            "recipe_kind": "crafting",
            "output_entity_type": "product",
            "output_game_id": "CIRCUITBOARD",
            "output_amount": "1",
            "time_seconds": "",
            "recipe_type": "Fabricator",
            "recipe_name": "Circuit Board",
            "source_ordinal": "0",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
        {
            "recipe_id": "cooking:product:FOOD_COOKED:0",
            "recipe_kind": "cooking",
            "output_entity_type": "product",
            "output_game_id": "FOOD_COOKED",
            "output_amount": "1",
            "time_seconds": "5",
            "recipe_type": "Nutrient Processor",
            "recipe_name": "Cooked Meat",
            "source_ordinal": "0",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
        {
            "recipe_id": "refining:substance:FUEL1:0",
            "recipe_kind": "refining",
            "output_entity_type": "substance",
            "output_game_id": "FUEL1",
            "output_amount": "2",
            "time_seconds": "0.6",
            "recipe_type": "Refine",
            "recipe_name": "",
            "source_ordinal": "0",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
    ]
    write_csv(
        import_dir / "recipes.csv",
        [
            "recipe_id", "recipe_kind", "output_entity_type", "output_game_id",
            "output_amount", "time_seconds", "recipe_type", "recipe_name",
            "source_ordinal", "attributes", "source_commit_sha",
        ],
        recipes,
    )

    ingredients = [
        {
            "recipe_id": "crafting:product:CIRCUITBOARD:0",
            "position": "0",
            "ingredient_entity_type": "substance",
            "ingredient_game_id": "FUEL1",
            "amount": "40",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
        {
            "recipe_id": "cooking:product:FOOD_COOKED:0",
            "position": "0",
            "ingredient_entity_type": "product",
            "ingredient_game_id": "FOOD_COOKED",
            "amount": "1",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
        {
            "recipe_id": "refining:substance:FUEL1:0",
            "position": "0",
            "ingredient_entity_type": "substance",
            "ingredient_game_id": "FUEL1",
            "amount": "1",
            "attributes": "{}",
            "source_commit_sha": COMMIT,
        },
    ]
    write_csv(
        import_dir / "recipe_ingredients.csv",
        [
            "recipe_id", "position", "ingredient_entity_type",
            "ingredient_game_id", "amount", "attributes", "source_commit_sha",
        ],
        ingredients,
    )

    content = [
        {
            "dataset": "expeditions",
            "external_id": "EXPEDITION_1",
            "source_ordinal": "0",
            "display_name": "Pioneers",
            "icon_source_path": "",
            "payload": '{"Id":"EXPEDITION_1","Name":"Pioneers"}',
            "source_commit_sha": COMMIT,
        }
    ]
    write_csv(
        import_dir / "content_records.csv",
        [
            "dataset", "external_id", "source_ordinal", "display_name",
            "icon_source_path", "payload", "source_commit_sha",
        ],
        content,
    )

    # Present in the transform output but must not be packed.
    write_csv(
        import_dir / "source_records.csv",
        ["dataset", "external_id", "source_ordinal", "payload", "payload_sha256"],
        [
            {
                "dataset": "substances",
                "external_id": "FUEL1",
                "source_ordinal": "0",
                "payload": '{"Id":"FUEL1"}',
                "payload_sha256": "a" * 64,
            }
        ],
    )
    write_csv(
        import_dir / "assets.csv",
        [
            "source_commit_sha", "source_path", "upstream_png_path",
            "storage_bucket", "storage_path", "mime_type", "content_sha256",
            "byte_size", "status", "referenced_by",
        ],
        [
            {
                "source_commit_sha": COMMIT,
                "source_path": "TEXTURES/UI/FUEL1.DDS",
                "upstream_png_path": "TEXTURES/UI/FUEL1.PNG",
                "storage_bucket": "",
                "storage_path": "",
                "mime_type": "image/png",
                "content_sha256": "",
                "byte_size": "",
                "status": "referenced",
                "referenced_by": '["substances"]',
            }
        ],
    )

    outputs = {}
    for name in (
        "source_records.csv",
        "entities.csv",
        "localizations.csv",
        "recipes.csv",
        "recipe_ingredients.csv",
        "content_records.csv",
        "assets.csv",
    ):
        path = import_dir / name
        with path.open(encoding="utf-8") as handle:
            row_count = sum(1 for _ in handle) - 1
        outputs[name] = {
            "rows": row_count,
            "bytes": path.stat().st_size,
            "sha256": sha256_bytes(path.read_bytes()),
        }

    manifest = {
        "contract_version": 1,
        "source": {
            "repository": "https://github.com/ApexFatality93/NMS-Handbook",
            "commit_sha": COMMIT,
            "committed_at": "2026-02-20T00:00:00+00:00",
        },
        "outputs": outputs,
        "counts": {
            "entities": 3,
            "localizations": 2,
            "recipes": 3,
            "recipe_ingredients": 3,
            "content_records": 1,
        },
        "validation": {"passed": True, "errors": [], "warnings": []},
    }
    (import_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return import_dir


class BuildNmsSqliteTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.import_dir = fixture_import_dir(self.root)
        self.output_dir = self.root / "nms-sqlite"

    def tearDown(self):
        self.temp.cleanup()

    def build(self) -> Path:
        result = build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)
        self.assertEqual(result, 0)
        return self.output_dir / "nms-reference.sqlite"

    def test_rejects_stale_csv_hashes(self):
        entities = self.import_dir / "entities.csv"
        entities.write_text(entities.read_text(encoding="utf-8") + "\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)

    def test_rejects_unsupported_contract_version(self):
        manifest_path = self.import_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["contract_version"] = 2
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "Unsupported transform contract"):
            build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)

    def test_rejects_non_hex_source_commit(self):
        manifest_path = self.import_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["source"]["commit_sha"] = "z" * 40
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "40 lowercase hexadecimal"):
            build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)

    def test_rejects_manifest_count_mismatch(self):
        manifest_path = self.import_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["counts"]["entities"] += 1
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaisesRegex(ValueError, "Manifest row count mismatch"):
            build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)

    def test_failed_rebuild_preserves_previous_pack_and_sidecar(self):
        sqlite_path = self.build()
        sidecar_path = self.output_dir / "pack-manifest.json"
        previous_sqlite = sqlite_path.read_bytes()
        previous_sidecar = sidecar_path.read_bytes()

        entities_path = self.import_dir / "entities.csv"
        invalid_entities = entities_path.read_text(encoding="utf-8").replace(
            "substance,FUEL1",
            "invalid,FUEL1",
            1,
        )
        entities_path.write_text(invalid_entities, encoding="utf-8")
        manifest_path = self.import_dir / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["outputs"]["entities.csv"]["sha256"] = sha256_bytes(
            entities_path.read_bytes()
        )
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with self.assertRaises(sqlite3.IntegrityError):
            build_nms_sqlite.build_pack(self.import_dir, self.output_dir, quiet=True)

        self.assertEqual(sqlite_path.read_bytes(), previous_sqlite)
        self.assertEqual(sidecar_path.read_bytes(), previous_sidecar)
        self.assertFalse(any(self.output_dir.glob(".nms-pack-*")))

    def test_pack_contains_canonical_tables_not_private_source(self):
        sqlite_path = self.build()
        connection = sqlite3.connect(sqlite_path)
        try:
            tables = {
                row[0]
                for row in connection.execute(
                    "select name from sqlite_master where type = 'table'"
                )
            }
            self.assertIn("nms_entities", tables)
            self.assertIn("nms_recipes", tables)
            self.assertIn("nms_recipe_ingredients", tables)
            self.assertIn("nms_localizations", tables)
            self.assertIn("nms_content_records", tables)
            self.assertIn("pack_manifest", tables)
            self.assertNotIn("source_records", tables)
            self.assertNotIn("nms_assets", tables)
            self.assertEqual(
                connection.execute("select count(*) from nms_entities").fetchone()[0],
                3,
            )
            self.assertEqual(
                connection.execute("select count(*) from nms_localizations").fetchone()[0],
                1,
            )
            preferred = connection.execute(
                "select value from nms_localizations where localization_id = ?",
                ("UI_FUEL1_NAME",),
            ).fetchone()[0]
            self.assertEqual(preferred, "Ferrite Dust")
        finally:
            connection.close()

    def test_fts_finds_ferrite_dust_and_recipe_joins_work(self):
        sqlite_path = self.build()
        connection = sqlite3.connect(sqlite_path)
        try:
            rows = connection.execute(
                """
                select e.display_name, e.entity_type, e.game_id
                from nms_entities_fts
                join nms_entities e
                  on e.entity_type = nms_entities_fts.entity_type
                 and e.game_id = nms_entities_fts.game_id
                where nms_entities_fts match ?
                order by bm25(nms_entities_fts, 10.0, 10.0, 3.0, 1.0)
                """,
                (build_nms_sqlite.fts_match_query("ferrite dust"),),
            ).fetchall()
            self.assertEqual(rows[0][0], "Ferrite Dust")

            using = connection.execute(
                """
                select r.recipe_id, r.recipe_kind
                from nms_recipe_ingredients i
                join nms_recipes r on r.recipe_id = i.recipe_id
                where i.ingredient_entity_type = ? and i.ingredient_game_id = ?
                order by r.recipe_id
                """,
                ("substance", "FUEL1"),
            ).fetchall()
            self.assertEqual(
                [row[0] for row in using],
                [
                    "crafting:product:CIRCUITBOARD:0",
                    "refining:substance:FUEL1:0",
                ],
            )

            content = connection.execute(
                """
                select dataset, display_name
                from nms_content_fts
                where nms_content_fts match ?
                """,
                (build_nms_sqlite.fts_match_query("pioneers"),),
            ).fetchone()
            self.assertEqual(content, ("expeditions", "Pioneers"))
        finally:
            connection.close()

    def test_sidecar_records_counts_and_file_hash(self):
        sqlite_path = self.build()
        sidecar = json.loads(
            (self.output_dir / "pack-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(sidecar["source_commit_sha"], COMMIT)
        self.assertEqual(sidecar["contract_version"], 1)
        self.assertEqual(sidecar["pack_role"], "production")
        self.assertEqual(sidecar["counts"]["entities"], 3)
        self.assertEqual(sidecar["counts"]["localizations_preferred"], 1)
        self.assertEqual(sidecar["sqlite"]["sha256"], sha256_bytes(sqlite_path.read_bytes()))
        self.assertTrue(sidecar["validation"]["passed"])

    def test_preview_role_is_explicit(self):
        build_nms_sqlite.build_pack(
            self.import_dir,
            self.output_dir,
            quiet=True,
            pack_role="preview",
        )
        sidecar = json.loads(
            (self.output_dir / "pack-manifest.json").read_text(encoding="utf-8")
        )
        self.assertEqual(sidecar["pack_role"], "preview")

    def test_rejects_unknown_pack_role(self):
        with self.assertRaisesRegex(ValueError, "Unsupported pack role"):
            build_nms_sqlite.build_pack(
                self.import_dir,
                self.output_dir,
                quiet=True,
                pack_role="nightly",
            )


if __name__ == "__main__":
    unittest.main()
