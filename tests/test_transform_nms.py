import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "transform_nms.py"
SPEC = importlib.util.spec_from_file_location("transform_nms", MODULE_PATH)
transform_nms = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(transform_nms)


class TransformHelpersTests(unittest.TestCase):
    def test_compact_json_is_stable(self):
        self.assertEqual(
            transform_nms.compact_json({"b": 2, "a": "é"}),
            '{"a":"é","b":2}',
        )

    def test_source_records_preserves_array_duplicates(self):
        rows = list(transform_nms.source_records([
            {"Id": "SAME", "English": "first"},
            {"Id": "SAME", "English": "second"},
        ]))
        self.assertEqual(rows[0][0], "SAME")
        self.assertEqual(rows[0][1], 0)
        self.assertEqual(rows[1][0], "SAME")
        self.assertEqual(rows[1][1], 1)

    def test_source_records_uses_object_key(self):
        rows = list(transform_nms.source_records({"GAME_ID": {"ProductId": "other"}}))
        self.assertEqual(rows[0][0], "GAME_ID")

    def test_asset_scanner_finds_nested_texture_paths(self):
        payload = {"nested": [{"Icon_Filename": "TEXTURES/UI/ICON.DDS"}]}
        self.assertEqual(
            list(transform_nms.iter_asset_strings(payload)),
            ["TEXTURES/UI/ICON.DDS"],
        )

    def test_numeric_text_normalizes_and_reports_invalid_values(self):
        errors = []
        self.assertEqual(transform_nms.numeric_text("1.5000", "x", errors), "1.5000")
        self.assertEqual(transform_nms.numeric_text("", "x", errors), "")
        self.assertEqual(transform_nms.numeric_text("nope", "x", errors), "")
        self.assertEqual(len(errors), 1)


if __name__ == "__main__":
    unittest.main()
