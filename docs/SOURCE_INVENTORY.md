# NMS-Handbook source inventory

Inventory date: 2026-08-29
Repository: `ApexFatality93/NMS-Handbook`
Pinned commit: `142d9ffd8078944722243398202f22cbef47cd02`
Commit date: 2026-02-20
Declared repository license: GPL-3.0

## Repository profile

- 7,097 tracked tree entries.
- Approximately 707 MB in the current tree.
- GitHub reports approximately 1.2 GB of repository storage/history.
- 6,869 PNG files in the repository.
- `TEXTURES/` alone accounts for approximately 573 MB.
- 19 usable JSON datasets totaling approximately 25 MB.
- 20 Python files totaling approximately 88 KB.
- No tags or GitHub releases; `main` must be resolved to a commit SHA.

The preferred ingestion boundary is `JSON_Files/`. `Game Files/` and `Lang
Files/` are upstream MXML inputs; `Python Files/` contains the regeneration
logic. The static website is not part of the database ingestion path.

## Dataset inventory

| Source file | Shape | Records | Canonical destination |
|---|---:|---:|---|
| `All_Lang_Data.json` | array | 79,756 | `nms_localizations` |
| `Bait_Table.json` | ID-keyed object | 621 | `nms_content_records` |
| `Building_Parts_Table.json` | ID-keyed object | 1,654 | `nms_content_records` |
| `Cooking_Table.json` | ID-keyed object | 333 outputs / 1,323 recipes | recipe tables |
| `Corvette_Parts_Table.json` | ID-keyed object | 633 | `nms_content_records` |
| `Crafting_Table.json` | ID-keyed object | 501 | recipe tables |
| `Expedition_Table.json` | ID-keyed object | 21 | `nms_content_records` |
| `Fish_Table.json` | ID-keyed object | 226 | `nms_content_records` |
| `Fossil_Table.json` | ID-keyed object | 143 | `nms_content_records` |
| `Legacy_Item_Table.json` | ID-keyed object | 20 | `nms_content_records` |
| `Product_Table.json` | ID-keyed object | 2,103 | `nms_entities` |
| `Purchaseable_Building_Blueprints.json` | ID-keyed object | 217 | `nms_content_records` |
| `Refining_Table.json` | ID-keyed object | 70 outputs / 357 recipes | recipe tables |
| `Ship_Part_Table.json` | ID-keyed object | 284 | `nms_content_records` |
| `Special_Purchase_Table.json` | ID-keyed object | 332 | `nms_content_records` |
| `Special_Rewards_Table.json` | ID-keyed object | 594 | `nms_content_records` |
| `Story_Table.json` | ID-keyed object | 7 categories | `nms_content_records` |
| `Substance_Table.json` | ID-keyed object | 107 | `nms_entities` |
| `Technology_Table.json` | ID-keyed object | 387 | `nms_entities` |

Top-level record total: 88,009. Recipes contain 4,003 ordered ingredient
relationships across crafting, refining, and cooking.

## Observed source-quality constraints

- IDs are inconsistent: `ProductId`, `ProductID`, `TechnologyId`, `ID`, or only
  the enclosing JSON object key. The enclosing key is authoritative for
  ID-keyed files.
- Numeric and boolean values are frequently encoded as strings.
- Empty strings are used in place of nulls.
- Ingredient records duplicate display text, icon paths, and colors from their
  referenced entities.
- `All_Lang_Data.json` contains 23 duplicate localization IDs with conflicting
  values (25 extra rows). Atlas preserves all rows and marks the last committed
  array occurrence as preferred because that matches the upstream dictionary
  construction behavior.
- Asset references normally point to DDS paths while the repository serves PNG
  conversions. Path casing is inconsistent and must be resolved against the Git
  tree case-insensitively.
- The upstream update scripts have an explicit dependency order: localization,
  products, substances, building parts, then remaining generators.

## Update and provenance policy

Every import records:

- Repository URL.
- Full resolved commit SHA.
- Commit date when available.
- SHA-256 of every imported source file.
- Record counts per source and output.
- Transformer version/commit.
- Validation findings.
- Asset-manifest coverage.

The `main` branch is a discovery pointer, not a production version identifier.
