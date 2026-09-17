import csv
import importlib.util
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "pack_nms_icons.py"
SPEC = importlib.util.spec_from_file_location("pack_nms_icons", MODULE_PATH)
pack_nms_icons = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(pack_nms_icons)


class PackNmsIconsTests(unittest.TestCase):
    def test_locator_path_lowercases_dds_to_png(self):
        self.assertEqual(
            pack_nms_icons.pack_relative_path(
                "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS"
            ),
            "icons/textures/ui/frontend/icons/fish/product2.fish.jelly.png",
        )

    def test_copies_fetched_png_to_locator_path_and_skips_missing(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fetch_dir = root / "nms-assets"
            pack_dir = root / "nms-sqlite"
            commit = "142d9ffd8078944722243398202f22cbef47cd02"
            upstream = "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.png"
            source = fetch_dir / commit / upstream
            source.parent.mkdir(parents=True)
            source.write_bytes(b"png")
            manifest = root / "assets.csv"
            with manifest.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(
                    handle,
                    fieldnames=[
                        "source_commit_sha",
                        "source_path",
                        "upstream_png_path",
                        "status",
                    ],
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "source_commit_sha": commit,
                        "source_path": "TEXTURES/UI/FRONTEND/ICONS/FISH/PRODUCT2.FISH.JELLY.DDS",
                        "upstream_png_path": upstream,
                        "status": "referenced",
                    }
                )
                writer.writerow(
                    {
                        "source_commit_sha": commit,
                        "source_path": "TEXTURES/MISSING.DDS",
                        "upstream_png_path": "TEXTURES/MISSING.png",
                        "status": "referenced",
                    }
                )
            counts = pack_nms_icons.pack_icons(
                asset_manifest=manifest,
                fetch_dir=fetch_dir,
                pack_dir=pack_dir,
            )
            packed = (
                pack_dir
                / "icons/textures/ui/frontend/icons/fish/product2.fish.jelly.png"
            )
            self.assertTrue(packed.is_file())
            self.assertEqual(packed.read_bytes(), b"png")
            self.assertFalse((pack_dir / "icons/textures/missing.png").exists())
            self.assertEqual(counts["copied"], 1)
            self.assertEqual(counts["referenced"], 2)
            self.assertEqual(counts["missing"], 1)


if __name__ == "__main__":
    unittest.main()
