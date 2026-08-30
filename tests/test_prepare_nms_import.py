import base64
import importlib.util
import json
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "scripts" / "prepare_nms_import.py"
SPEC = importlib.util.spec_from_file_location("prepare_nms_import", MODULE_PATH)
prepare_nms_import = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(prepare_nms_import)


class PrepareImportTests(unittest.TestCase):
    def test_decode_csv_value_preserves_json_and_types(self):
        self.assertEqual(
            prepare_nms_import.decode_csv_value("attributes", '{"x":1}'),
            {"x": 1},
        )
        self.assertEqual(
            prepare_nms_import.decode_csv_value("source_ordinal", "12"),
            12,
        )
        self.assertIs(
            prepare_nms_import.decode_csv_value("is_preferred", "true"),
            True,
        )
        self.assertIsNone(prepare_nms_import.decode_csv_value("name", ""))

    def test_record_identity_keeps_duplicate_localizations_distinct(self):
        first = {
            "localization_id": "SAME",
            "locale": "en",
            "source_ordinal": 10,
        }
        second = dict(first, source_ordinal=11)
        self.assertEqual(
            prepare_nms_import.record_identity("localizations", first),
            ("SAME:en", 10),
        )
        self.assertNotEqual(
            prepare_nms_import.record_identity("localizations", first),
            prepare_nms_import.record_identity("localizations", second),
        )

    def test_chunk_rows_respects_byte_limit_without_losing_rows(self):
        rows = [{"id": index, "value": "x" * 30} for index in range(8)]
        chunks = list(prepare_nms_import.chunk_rows(rows, 150))
        self.assertGreater(len(chunks), 1)
        self.assertEqual([row for chunk in chunks for row in chunk], rows)
        for chunk in chunks:
            encoded = prepare_nms_import.compact_json(chunk).encode("utf-8")
            self.assertLessEqual(len(encoded), 150)

    def test_encoded_json_sql_round_trips(self):
        value = [{"text": "Ferrite é", "number": 3}]
        sql = prepare_nms_import.encoded_json_sql(value)
        encoded = sql.split("decode('", 1)[1].split("'", 1)[0]
        decoded = json.loads(base64.b64decode(encoded).decode("utf-8"))
        self.assertEqual(decoded, value)

    def test_import_id_is_deterministic(self):
        source = "https://example.test/repo@" + "a" * 40
        first = prepare_nms_import.uuid.uuid5(
            prepare_nms_import.IMPORT_NAMESPACE,
            source,
        )
        second = prepare_nms_import.uuid.uuid5(
            prepare_nms_import.IMPORT_NAMESPACE,
            source,
        )
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
