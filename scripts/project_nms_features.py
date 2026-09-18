"""Project typed feature tables from lossless nms_content_records payloads."""

from __future__ import annotations

import json
from typing import Any

KNOWN_DATASETS = (
    "bait",
    "building_parts",
    "corvette_parts",
    "expeditions",
    "fish",
    "fossils",
    "legacy_items",
    "purchaseable_building_blueprints",
    "ship_parts",
    "special_purchases",
    "special_rewards",
    "stories",
)

FEATURE_DDL = """
        create table nms_fish (
          external_id text not null,
          source_ordinal integer not null,
          product_id text,
          title text,
          subtitle text,
          description text,
          quality text,
          size text,
          time_of_day text,
          needs_storm integer,
          requires_mission text,
          mission_seed text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_fish_quality_idx on nms_fish (quality);
        create index nms_fish_time_idx on nms_fish (time_of_day);
        create index nms_fish_size_idx on nms_fish (size);
        create index nms_fish_storm_idx on nms_fish (needs_storm);

        create table nms_fish_biomes (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          biome text not null,
          primary key (external_id, source_ordinal, position)
        );
        create index nms_fish_biomes_biome_idx on nms_fish_biomes (biome);

        create table nms_bait (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          used_for text,
          rarity_percent text,
          size_percent text,
          source_kind text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_bait_used_for_idx on nms_bait (used_for);

        create table nms_building_parts (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          wiki_category text,
          not_enabled integer not null default 0,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_building_parts_enabled_idx on nms_building_parts (not_enabled);

        create table nms_building_part_requirements (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          entity_type text,
          game_id text,
          amount text,
          title text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal, position)
        );
        create index nms_building_parts_category_idx on nms_building_parts (wiki_category);
        create index nms_building_part_requirements_material_idx
          on nms_building_part_requirements (game_id, entity_type);

        create table nms_ship_parts (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          subtitle text,
          ship_type text,
          category text,
          rarity text,
          base_value text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_ship_parts_type_idx on nms_ship_parts (ship_type);
        create index nms_ship_parts_category_idx on nms_ship_parts (category);

        create table nms_corvette_parts (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          wiki_category text,
          not_enabled integer not null default 0,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_corvette_parts_enabled_idx on nms_corvette_parts (not_enabled);

        create table nms_corvette_part_categories (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          category text not null,
          primary key (external_id, source_ordinal, position)
        );
        create index nms_corvette_part_categories_idx on nms_corvette_part_categories (category);

        create table nms_corvette_part_requirements (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          entity_type text,
          game_id text,
          amount text,
          title text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal, position)
        );

        create table nms_special_rewards (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_special_reward_sources (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          source_label text not null,
          primary key (external_id, source_ordinal, position)
        );
        create index nms_special_reward_sources_idx on nms_special_reward_sources (source_label);

        create table nms_special_purchases (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_fossils (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          category text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );
        create index nms_fossils_category_idx on nms_fossils (category);

        create table nms_legacy_items (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          converts_to text,
          conversion_ratio text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_building_blueprints (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_expeditions (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_stories (
          external_id text not null,
          source_ordinal integer not null,
          title text,
          icon_source_path text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal)
        );

        create table nms_story_pages (
          external_id text not null,
          source_ordinal integer not null,
          position integer not null,
          title text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal, position)
        );

        create table nms_story_entries (
          external_id text not null,
          source_ordinal integer not null,
          page_position integer not null,
          position integer not null,
          title text,
          body text,
          extra_json text not null default '{}',
          primary key (external_id, source_ordinal, page_position, position)
        );
        """


def _text(value: Any) -> str | None:
    if value is None or value == "":
        return None
    return str(value)


def _bool01(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return 1 if value else 0
    text = str(value).strip().lower()
    if text in {"1", "true", "yes"}:
        return 1
    if text in {"0", "false", "no"}:
        return 0
    return None


def _extra(payload: dict[str, Any], known: set[str]) -> str:
    leftover = {key: payload[key] for key in payload if key not in known}
    return json.dumps(leftover, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _title(payload: dict[str, Any]) -> str | None:
    return _text(
        payload.get("NameLower_Text")
        or payload.get("Name_Text")
        or payload.get("SeasonName")
        or payload.get("RewardName")
        or payload.get("CategoryText")
        or payload.get("DisplayName")
    )


def _icon(payload: dict[str, Any]) -> str | None:
    return _text(
        payload.get("Icon_Filename")
        or payload.get("PageIcon")
        or payload.get("IconOn")
    )


def _requirement_identity(item: dict[str, Any]) -> tuple[str | None, str | None]:
    game_id = _text(
        item.get("Id")
        or item.get("ID")
        or item.get("ProductId")
        or item.get("ProductID")
        or item.get("SubstanceId")
    )
    raw_type = _text(item.get("Type") or item.get("EntityType") or item.get("InventoryType"))
    if raw_type:
        lowered = raw_type.lower()
        if "substance" in lowered:
            entity_type = "substance"
        elif "tech" in lowered:
            entity_type = "technology"
        else:
            entity_type = "product"
    else:
        entity_type = None
    return entity_type, game_id


def _requirements(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw = payload.get("Requirements") or payload.get("Requirement") or []
    if isinstance(raw, dict):
        raw = [raw]
    if not isinstance(raw, list):
        return []
    rows = []
    for item in raw:
        if isinstance(item, dict):
            rows.append(item)
    return rows


def decode_payload(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return decoded if isinstance(decoded, dict) else {}


def project_content_records(connection: Any, records: list[dict[str, Any]]) -> dict[str, int]:
    counts = {dataset: 0 for dataset in KNOWN_DATASETS}
    counts["fish_biomes"] = 0
    counts["building_part_requirements"] = 0
    counts["corvette_part_categories"] = 0
    counts["corvette_part_requirements"] = 0
    counts["special_reward_sources"] = 0
    counts["story_pages"] = 0
    counts["story_entries"] = 0
    counts["unknown_datasets"] = 0

    for record in records:
        dataset = record["dataset"]
        payload = decode_payload(record.get("payload"))
        if dataset == "fish":
            _project_fish(connection, record, payload, counts)
        elif dataset == "bait":
            _project_bait(connection, record, payload, counts)
        elif dataset == "building_parts":
            _project_building_part(connection, record, payload, counts)
        elif dataset == "ship_parts":
            _project_ship_part(connection, record, payload, counts)
        elif dataset == "corvette_parts":
            _project_corvette_part(connection, record, payload, counts)
        elif dataset == "special_rewards":
            _project_reward(connection, record, payload, counts)
        elif dataset == "special_purchases":
            _project_purchase(connection, record, payload, counts)
        elif dataset == "fossils":
            _project_fossil(connection, record, payload, counts)
        elif dataset == "legacy_items":
            _project_legacy(connection, record, payload, counts)
        elif dataset == "purchaseable_building_blueprints":
            _project_blueprint(connection, record, payload, counts)
        elif dataset == "expeditions":
            _project_expedition(connection, record, payload, counts)
        elif dataset == "stories":
            _project_story(connection, record, payload, counts)
        else:
            counts["unknown_datasets"] += 1
    return counts


def _ids(record: dict[str, Any]) -> tuple[str, int]:
    return str(record["external_id"]), int(record["source_ordinal"])


def _project_fish(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "ProductID", "NameLower_Text", "Subtitle_Text", "Description_Text",
        "Icon_Filename", "Quality", "Size", "Time", "NeedsStorm",
        "RequiresMissionActive", "MissionSeed", "Biomes",
    }
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_fish (
          external_id, source_ordinal, product_id, title, subtitle, description,
          quality, size, time_of_day, needs_storm, requires_mission, mission_seed,
          icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _text(payload.get("ProductID")) or external_id,
            _title(payload) or _text(record.get("display_name")),
            _text(payload.get("Subtitle_Text")),
            _text(payload.get("Description_Text")),
            _text(payload.get("Quality")),
            _text(payload.get("Size")),
            _text(payload.get("Time")),
            _bool01(payload.get("NeedsStorm")),
            _text(payload.get("RequiresMissionActive")),
            _text(payload.get("MissionSeed")),
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["fish"] += 1
    biomes = payload.get("Biomes") or []
    if isinstance(biomes, str):
        biomes = [biomes]
    for position, biome in enumerate(biomes if isinstance(biomes, list) else []):
        if not isinstance(biome, str) or not biome:
            continue
        connection.execute(
            """
            insert into nms_fish_biomes (external_id, source_ordinal, position, biome)
            values (?, ?, ?, ?)
            """,
            (external_id, ordinal, position, biome),
        )
        counts["fish_biomes"] += 1


def _project_bait(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "NameLower_Text", "Icon_Filename", "RarityPercent", "SizePercent",
        "UsedFor", "Source",
    }
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_bait (
          external_id, source_ordinal, title, used_for, rarity_percent,
          size_percent, source_kind, icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            _text(payload.get("UsedFor")),
            _text(payload.get("RarityPercent")),
            _text(payload.get("SizePercent")),
            _text(payload.get("Source")),
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["bait"] += 1


def _project_building_part(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "NameLower_Text", "Name_Text", "Icon_Filename", "WikiCategory",
        "Requirements", "Requirement",
    }
    wiki = _text(payload.get("WikiCategory"))
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_building_parts (
          external_id, source_ordinal, title, wiki_category, not_enabled,
          icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            wiki,
            1 if wiki == "NotEnabled" else 0,
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["building_parts"] += 1
    for position, item in enumerate(_requirements(payload)):
        entity_type, game_id = _requirement_identity(item)
        connection.execute(
            """
            insert into nms_building_part_requirements (
              external_id, source_ordinal, position, entity_type, game_id, amount, title, extra_json
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                external_id,
                ordinal,
                position,
                entity_type,
                game_id,
                _text(item.get("Amount") or item.get("Quantity")),
                _text(item.get("NameLower_Text") or item.get("Name_Text")),
                _extra(
                    item,
                    {
                        "Id", "ID", "ProductId", "ProductID", "SubstanceId", "Type",
                        "EntityType", "InventoryType", "Amount", "Quantity",
                        "NameLower_Text", "Name_Text",
                    },
                ),
            ),
        )
        counts["building_part_requirements"] += 1


def _project_ship_part(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "NameLower_Text", "Name_Text", "Subtitle_Text", "BaseValue",
        "Icon_Filename", "Category", "Type", "Rarity",
    }
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_ship_parts (
          external_id, source_ordinal, title, subtitle, ship_type, category,
          rarity, base_value, icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            _text(payload.get("Subtitle_Text")),
            _text(payload.get("Type")),
            _text(payload.get("Category")),
            _text(payload.get("Rarity")),
            _text(payload.get("BaseValue")),
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["ship_parts"] += 1


def _project_corvette_part(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "NameLower_Text", "Name_Text", "Icon_Filename", "WikiCategory", "Category",
        "Categories", "Requirements", "Requirement",
    }
    wiki = _text(payload.get("WikiCategory"))
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_corvette_parts (
          external_id, source_ordinal, title, wiki_category, not_enabled,
          icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            wiki,
            1 if wiki == "NotEnabled" else 0,
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["corvette_parts"] += 1
    categories = payload.get("Categories") or payload.get("Category") or []
    if isinstance(categories, str):
        categories = [part.strip() for part in categories.replace("/", ",").split(",") if part.strip()]
    if not isinstance(categories, list):
        categories = []
    for position, category in enumerate(categories):
        label = category if isinstance(category, str) else _text(category)
        if not label:
            continue
        connection.execute(
            """
            insert into nms_corvette_part_categories (
              external_id, source_ordinal, position, category
            ) values (?, ?, ?, ?)
            """,
            (external_id, ordinal, position, label),
        )
        counts["corvette_part_categories"] += 1
    for position, item in enumerate(_requirements(payload)):
        entity_type, game_id = _requirement_identity(item)
        connection.execute(
            """
            insert into nms_corvette_part_requirements (
              external_id, source_ordinal, position, entity_type, game_id, amount, title, extra_json
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                external_id,
                ordinal,
                position,
                entity_type,
                game_id,
                _text(item.get("Amount") or item.get("Quantity")),
                _text(item.get("NameLower_Text") or item.get("Name_Text")),
                _extra(
                    item,
                    {
                        "Id", "ID", "ProductId", "ProductID", "SubstanceId", "Type",
                        "EntityType", "InventoryType", "Amount", "Quantity",
                        "NameLower_Text", "Name_Text",
                    },
                ),
            ),
        )
        counts["corvette_part_requirements"] += 1


def _project_reward(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "ID", "RewardName", "NameLower_Text", "Name_Text", "Icon_Filename",
        "Sources", "Source", "RewardType",
    }
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_special_rewards (
          external_id, source_ordinal, title, icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["special_rewards"] += 1
    sources = payload.get("Sources") or payload.get("Source") or payload.get("RewardType") or []
    if isinstance(sources, str):
        sources = [sources]
    if not isinstance(sources, list):
        sources = []
    for position, source in enumerate(sources):
        label = source if isinstance(source, str) else _text(source)
        if not label:
            continue
        connection.execute(
            """
            insert into nms_special_reward_sources (
              external_id, source_ordinal, position, source_label
            ) values (?, ?, ?, ?)
            """,
            (external_id, ordinal, position, label),
        )
        counts["special_reward_sources"] += 1


def _project_simple(
    connection: Any,
    table: str,
    count_key: str,
    record: dict[str, Any],
    payload: dict[str, Any],
    counts: dict[str, int],
    extra_fields: tuple[str, ...] = (),
    extra_values: tuple[Any, ...] = (),
    known: set[str] | None = None,
) -> None:
    known = known or {
        "NameLower_Text", "Name_Text", "Icon_Filename", "RewardName",
        "SeasonName", "CategoryText", "Category",
    }
    columns = ["external_id", "source_ordinal", "title", *extra_fields, "icon_source_path", "extra_json"]
    values = (
        *_ids(record),
        _title(payload) or _text(record.get("display_name")),
        *extra_values,
        _icon(payload) or _text(record.get("icon_source_path")),
        _extra(payload, known),
    )
    placeholders = ", ".join("?" * len(columns))
    connection.execute(
        f"insert into {table} ({', '.join(columns)}) values ({placeholders})",
        values,
    )
    counts[count_key] += 1


def _project_purchase(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    _project_simple(connection, "nms_special_purchases", "special_purchases", record, payload, counts)


def _project_fossil(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    _project_simple(
        connection,
        "nms_fossils",
        "fossils",
        record,
        payload,
        counts,
        extra_fields=("category",),
        extra_values=(_text(payload.get("FossilCategory") or payload.get("Category") or payload.get("Type")),),
        known={
            "NameLower_Text", "Name_Text", "Icon_Filename", "FossilCategory",
        },
    )


def _project_legacy(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    _project_simple(
        connection,
        "nms_legacy_items",
        "legacy_items",
        record,
        payload,
        counts,
        extra_fields=("converts_to", "conversion_ratio"),
        extra_values=(
            _text(payload.get("ConvertID") or payload.get("ConvertTo") or payload.get("NewId")),
            _text(
                payload.get("ConvertRatio")
                or payload.get("Ratio")
                or payload.get("ConversionRatio")
                or payload.get("Value")
            ),
        ),
        known={
            "NameLower_Text", "Name_Text", "Icon_Filename", "ConvertID", "ConvertRatio",
        },
    )


def _project_blueprint(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    _project_simple(
        connection,
        "nms_building_blueprints",
        "purchaseable_building_blueprints",
        record,
        payload,
        counts,
    )


def _project_expedition(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    _project_simple(
        connection,
        "nms_expeditions",
        "expeditions",
        record,
        payload,
        counts,
        known={"Id", "Name", "SeasonName", "NameLower_Text", "Name_Text", "Icon_Filename"},
    )


def _project_story(connection: Any, record: dict[str, Any], payload: dict[str, Any], counts: dict[str, int]) -> None:
    known = {
        "CategoryText", "CategoryID", "NameLower_Text", "Name_Text", "PageIcon",
        "IconOn", "IconOff", "Icon_Filename", "Pages",
    }
    external_id, ordinal = _ids(record)
    connection.execute(
        """
        insert into nms_stories (
          external_id, source_ordinal, title, icon_source_path, extra_json
        ) values (?, ?, ?, ?, ?)
        """,
        (
            external_id,
            ordinal,
            _title(payload) or _text(record.get("display_name")),
            _icon(payload) or _text(record.get("icon_source_path")),
            _extra(payload, known),
        ),
    )
    counts["stories"] += 1
    pages = payload.get("Pages") or []
    if not isinstance(pages, list):
        return
    for page_position, page in enumerate(pages):
        if not isinstance(page, dict):
            continue
        connection.execute(
            """
            insert into nms_story_pages (
              external_id, source_ordinal, position, title, extra_json
            ) values (?, ?, ?, ?, ?)
            """,
            (
                external_id,
                ordinal,
                page_position,
                _text(page.get("PageText") or page.get("Title") or page.get("Name") or page.get("PageTitle")),
                _extra(page, {"Title", "Name", "PageTitle", "PageText", "PageIcon", "Entries"}),
            ),
        )
        counts["story_pages"] += 1
        entries = page.get("Entries") or []
        if not isinstance(entries, list):
            continue
        for entry_position, entry in enumerate(entries):
            if not isinstance(entry, dict):
                continue
            connection.execute(
                """
                insert into nms_story_entries (
                  external_id, source_ordinal, page_position, position, title, body, extra_json
                ) values (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    external_id,
                    ordinal,
                    page_position,
                    entry_position,
                    _text(entry.get("TitleText") or entry.get("Title") or entry.get("Name")),
                    _text(entry.get("EntryText") or entry.get("Text") or entry.get("Body") or entry.get("Entry")),
                    _extra(
                        entry,
                        {
                            "Title", "Name", "TitleText", "TitleID", "Text", "Body",
                            "Entry", "EntryText", "EntryID",
                        },
                    ),
                ),
            )
            counts["story_entries"] += 1
