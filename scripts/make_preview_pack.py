#!/usr/bin/env python3
"""Build the small disposable SQLite fixture used by AtlasTests."""

from __future__ import annotations

import importlib.util
import shutil
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_PATH = ROOT / "tests" / "test_build_nms_sqlite.py"
OUTPUT_DIR = ROOT / "apps" / "ios" / "AtlasTests" / "Fixtures"
SQLITE_OUTPUT = OUTPUT_DIR / "nms-reference.sqlite"
SIDECAR_OUTPUT = OUTPUT_DIR / "pack-manifest.json"


def main() -> int:
    spec = importlib.util.spec_from_file_location("test_build_nms_sqlite", TEST_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        import_dir = module.fixture_import_dir(root)
        output_dir = root / "sqlite"
        module.build_nms_sqlite.build_pack(
            import_dir,
            output_dir,
            pack_role="preview",
        )
        OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
        shutil.copy2(output_dir / "nms-reference.sqlite", SQLITE_OUTPUT)
        shutil.copy2(output_dir / "pack-manifest.json", SIDECAR_OUTPUT)
    print(f"Wrote {SQLITE_OUTPUT}")
    print(f"Wrote {SIDECAR_OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
