#!/usr/bin/env python3
"""Verify Atlas transform outputs and generate resumable SQL import batches."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import uuid
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import Any


IMPORT_NAMESPACE = uuid.UUID("27eb0b29-2919-4ce5-8c9e-16872f81bfda")
DEFAULT_MAX_BATCH_BYTES = 700_000

TARGETS = (
    ("source_records.csv", "source_records"),
    ("entities.csv", "entities"),
    ("localizations.csv", "localizations"),
    ("recipes.csv", "recipes"),
    ("recipe_ingredients.csv", "recipe_ingredients"),
    ("content_records.csv", "content_records"),
    ("assets.csv", "assets"),
)

JSON_FIELDS = {"payload", "attributes", "referenced_by"}
INTEGER_FIELDS = {"source_ordinal", "position", "byte_size"}
BOOLEAN_FIELDS = {"is_preferred"}


def compact_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def decode_csv_value(field: str, value: str) -> Any:
    if value == "":
        return None
    if field in JSON_FIELDS:
        return json.loads(value)
    if field in INTEGER_FIELDS:
        return int(value)
    if field in BOOLEAN_FIELDS:
        normalized = value.casefold()
        if normalized not in {"true", "false"}:
            raise ValueError(f"Invalid boolean for {field}: {value!r}")
        return normalized == "true"
    return value


def record_identity(target: str, payload: dict[str, Any]) -> tuple[str, int]:
    if target == "entities":
        return f"{payload['entity_type']}:{payload['game_id']}", 0
    if target == "localizations":
        return (
            f"{payload['localization_id']}:{payload['locale']}",
            int(payload["source_ordinal"]),
        )
    if target == "recipes":
        return str(payload["recipe_id"]), int(payload["source_ordinal"])
    if target == "recipe_ingredients":
        return str(payload["recipe_id"]), int(payload["position"])
    if target == "content_records":
        return (
            f"{payload['dataset']}:{payload['external_id']}",
            int(payload["source_ordinal"]),
        )
    if target == "assets":
        return str(payload["source_path"]), 0
    raise ValueError(f"No staged identity rule for target {target!r}")


def iter_import_rows(path: Path, target: str) -> Iterator[dict[str, Any]]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"CSV has no header: {path}")
        for row in reader:
            payload = {
                field: decode_csv_value(field, value)
                for field, value in row.items()
            }
            if target == "source_records":
                yield payload
                continue
            record_key, source_ordinal = record_identity(target, payload)
            encoded_payload = compact_json(payload).encode("utf-8")
            yield {
                "record_key": record_key,
                "source_ordinal": source_ordinal,
                "payload": payload,
                "payload_sha256": sha256_bytes(encoded_payload),
            }


def chunk_rows(
    rows: Iterable[dict[str, Any]],
    max_batch_bytes: int,
) -> Iterator[list[dict[str, Any]]]:
    batch: list[dict[str, Any]] = []
    batch_bytes = 2
    for row in rows:
        row_bytes = len(compact_json(row).encode("utf-8")) + (1 if batch else 0)
        if row_bytes + 2 > max_batch_bytes:
            raise ValueError(
                f"One import row requires {row_bytes + 2} bytes, exceeding "
                f"the {max_batch_bytes}-byte batch limit"
            )
        if batch and batch_bytes + row_bytes > max_batch_bytes:
            yield batch
            batch = []
            batch_bytes = 2
            row_bytes -= 1
        batch.append(row)
        batch_bytes += row_bytes
    if batch:
        yield batch


def encoded_json_sql(value: Any) -> str:
    encoded = base64.b64encode(compact_json(value).encode("utf-8")).decode("ascii")
    return f"convert_from(decode('{encoded}', 'base64'), 'UTF8')::jsonb"


def begin_sql(import_run_id: uuid.UUID, manifest: dict[str, Any]) -> str:
    manifest_sql = encoded_json_sql(manifest)
    return f"""-- Create or resume the deterministic import run.
with document as (
  select {manifest_sql} as manifest
)
insert into nms_private.import_runs (
  id, source_repository, source_commit_sha, source_committed_at,
  status, manifest, started_at, error_message
)
select
  '{import_run_id}'::uuid,
  manifest #>> '{{source,repository}}',
  manifest #>> '{{source,commit_sha}}',
  nullif(manifest #>> '{{source,committed_at}}', '')::timestamptz,
  'staged',
  manifest,
  now(),
  null
from document
on conflict (source_repository, source_commit_sha) do update set
  manifest = excluded.manifest,
  started_at = now(),
  error_message = null,
  status = case
    when nms_private.import_runs.status = 'active' then 'active'
    else 'staged'
  end
returning id, source_commit_sha, status;
"""


def batch_sql(
    import_run_id: uuid.UUID,
    target: str,
    rows: list[dict[str, Any]],
) -> str:
    rows_sql = encoded_json_sql(rows)
    if target == "source_records":
        return f"""-- Resumable source-record batch ({len(rows)} rows).
insert into nms_private.source_records (
  import_run_id, dataset, external_id, source_ordinal, payload, payload_sha256
)
select
  '{import_run_id}'::uuid,
  row_data.dataset,
  row_data.external_id,
  row_data.source_ordinal,
  row_data.payload,
  row_data.payload_sha256
from jsonb_to_recordset({rows_sql}) as row_data(
  dataset text,
  external_id text,
  source_ordinal integer,
  payload jsonb,
  payload_sha256 text
)
on conflict (import_run_id, dataset, external_id, source_ordinal)
do update set
  payload = excluded.payload,
  payload_sha256 = excluded.payload_sha256;
"""

    return f"""-- Resumable {target} staging batch ({len(rows)} rows).
insert into nms_private.staged_records (
  import_run_id, target, record_key, source_ordinal, payload, payload_sha256
)
select
  '{import_run_id}'::uuid,
  '{target}',
  row_data.record_key,
  row_data.source_ordinal,
  row_data.payload,
  row_data.payload_sha256
from jsonb_to_recordset({rows_sql}) as row_data(
  record_key text,
  source_ordinal integer,
  payload jsonb,
  payload_sha256 text
)
on conflict (import_run_id, target, record_key, source_ordinal)
do update set
  payload = excluded.payload,
  payload_sha256 = excluded.payload_sha256;
"""


def verify_manifest(import_dir: Path, manifest: dict[str, Any]) -> None:
    if manifest.get("contract_version") != 1:
        raise ValueError(
            f"Unsupported contract version: {manifest.get('contract_version')!r}"
        )
    if manifest.get("validation", {}).get("passed") is not True:
        raise ValueError("Transform manifest contains blocking validation errors")
    source_sha = manifest.get("source", {}).get("commit_sha", "")
    if len(source_sha) != 40 or any(char not in "0123456789abcdef" for char in source_sha):
        raise ValueError(f"Invalid source commit SHA: {source_sha!r}")

    for filename, _target in TARGETS:
        path = import_dir / filename
        output = manifest.get("outputs", {}).get(filename)
        if not path.is_file() or not output:
            raise ValueError(f"Missing generated output or manifest entry: {filename}")
        actual_hash = sha256_file(path)
        if actual_hash != output.get("sha256"):
            raise ValueError(
                f"Hash mismatch for {filename}: expected {output.get('sha256')}, "
                f"found {actual_hash}"
            )


def write_sql(path: Path, sql: str) -> dict[str, Any]:
    encoded = sql.encode("utf-8")
    path.write_bytes(encoded)
    return {
        "file": path.name,
        "bytes": len(encoded),
        "sha256": sha256_bytes(encoded),
    }


def prepare(args: argparse.Namespace) -> int:
    import_dir = args.import_dir.resolve()
    output_dir = args.output_dir.resolve()
    manifest_path = import_dir / "manifest.json"
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)

    verify_manifest(import_dir, manifest)
    source = manifest["source"]
    import_run_id = uuid.uuid5(
        IMPORT_NAMESPACE,
        f"{source['repository']}@{source['commit_sha']}",
    )

    output_dir.mkdir(parents=True, exist_ok=True)
    for old_file in output_dir.glob("*.sql"):
        old_file.unlink()

    plan_files: list[dict[str, Any]] = []
    plan_files.append(
        write_sql(output_dir / "0000_begin.sql", begin_sql(import_run_id, manifest))
    )

    sequence = 1
    target_counts: dict[str, int] = {}
    target_batches: dict[str, int] = {}
    for filename, target in TARGETS:
        row_count = 0
        batch_count = 0
        rows = iter_import_rows(import_dir / filename, target)
        for batch in chunk_rows(rows, args.max_batch_bytes):
            sql_name = f"{sequence:04d}_{target}.sql"
            plan_files.append(
                write_sql(
                    output_dir / sql_name,
                    batch_sql(import_run_id, target, batch),
                )
            )
            sequence += 1
            batch_count += 1
            row_count += len(batch)
        expected = int(manifest["outputs"][filename]["rows"])
        if row_count != expected:
            raise ValueError(
                f"Row count mismatch for {filename}: expected {expected}, found {row_count}"
            )
        target_counts[target] = row_count
        target_batches[target] = batch_count

    activation_name = f"{sequence:04d}_activate.sql"
    activation = (
        "-- Validate every staged count and atomically publish the import.\n"
        f"select nms_private.activate_import('{import_run_id}'::uuid);\n"
    )
    plan_files.append(write_sql(output_dir / activation_name, activation))

    plan = {
        "contract_version": manifest["contract_version"],
        "import_run_id": str(import_run_id),
        "source": source,
        "max_batch_bytes": args.max_batch_bytes,
        "target_counts": target_counts,
        "target_batches": target_batches,
        "files": plan_files,
    }
    plan_path = output_dir / "run.json"
    plan_path.write_text(
        json.dumps(plan, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    print(f"Import run: {import_run_id}")
    print(f"Source commit: {source['commit_sha']}")
    print(f"SQL directory: {output_dir}")
    for target in target_counts:
        print(
            f"  {target}: {target_counts[target]} rows "
            f"in {target_batches[target]} batches"
        )
    print(f"Plan: {plan_path}")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--import-dir",
        type=Path,
        default=Path("build/nms-import"),
        help="Validated transform output directory",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("build/nms-sql"),
        help="Generated resumable SQL batch directory",
    )
    parser.add_argument(
        "--max-batch-bytes",
        type=int,
        default=DEFAULT_MAX_BATCH_BYTES,
        help="Maximum unencoded JSON bytes per SQL batch",
    )
    args = parser.parse_args()
    if args.max_batch_bytes < 10_000:
        parser.error("--max-batch-bytes must be at least 10000")
    return args


if __name__ == "__main__":
    raise SystemExit(prepare(parse_args()))
