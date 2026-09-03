# Specialized experiences — Atlas

**Date:** 2026-09-03
**Status:** Later slices after the recipe planner and local saved-data store
**Canonical order:** [WORK_SLICES.md](WORK_SLICES.md)

This document keeps the screen and source-data rules for specialist
workspaces. It is not the current execution plan. Do Slice 1 (recipe planner)
and Slice 2 (local artifacts) first.

## Product rules that still apply

1. **Atlas is the front door.** Library, Saved, and Info stay first-class.
2. **The pack is the handbook.** Specialist screens read installed SQLite,
   including additive typed projections when a family needs filters.
3. **Every workspace has a deterministic path.** No model required.
4. **The model proposes; the app calculates.** Recipe totals, bait fields, and
   material sums are engine output, not generated prose.
5. **Writes are app-owned.** Saving a plan or checking a box is never a model
   tool.
6. **Capabilities must match the data.** Do not claim current expeditions,
   species-specific bait, or ship-part compatibility the pack does not have.

Live handbook HTTP is parked. Optional web search stays a labeled community
source. Optional user-data sync is Slice 8 and does not host the handbook.

## Shared pattern

```text
ask or browse -> typed local records -> native workspace -> save locally
```

Each family follows the same gate:

1. Write the player questions, filters, and unsupported claims.
2. Decode 100% of that family’s packed records in tests. Keep unknown fields.
3. Add typed SQLite projections only when generic `nms_content_records`
   cannot filter or calculate.
4. Ship collection, detail, and a Slice 2 artifact (list, progress, or note).
5. Gate the screen on pack capability, not only app version.

`nms_content_records` remains the compatibility fallback. Raw JSON is a
debug disclosure, not the long-term UI.

## Slice 1 — Recipe planner

**Why first:** 2,181 recipes and 4,003 ordered ingredients are already packed.

**Screens:** quantity, alternate craft/refine/cook paths, dependency tree,
totals, cycle explanation, saved checklist.

**Engine:** pure deterministic traversal. Bounds: depth 12, five alternatives
per node, 500 visited nodes, overflow-checked integer quantities 1...999,999.

**Save:** a Slice 2 `recipePlan` artifact with inputs, selected path, totals,
progress, engine version, and pack release. A pack change previews a new
revision; it does not silently overwrite.

**Done when:** known multi-step fixtures match exact totals; cycles do not
hang; the plan restores after relaunch.

## Slice 3 — Fish and bait

**Data:** 226 fish, 621 bait, all join canonical entities.

**Screens:** faceted fish list, detail with recipe uses, condition-aware bait
comparison.

**Rules:**

- Bait is General / Day / Night / Storm. Do not claim species-specific
  affinity.
- Show rarity and size bonuses separately. Do not invent a single rank.
- Nullable size and empty descriptions are “not recorded.”
- The source does not define how to combine bonuses.

**Done when:** every fish and bait record projects; facet counts match; every
canonical link resolves.

## Slice 4 — Expedition archive

**Data:** 21 seasons, 252 unique rewards, ordered reward groups.

**Screens:** historical season list, group detail, reward detail, local
owned/wanted tracking.

**Rules:**

- Label packed data **Historical**.
- The source has no dates, availability, milestones, or usable final-reward
  field.
- Do not infer meaning for the `-1` reward group.
- Preserve each reward array’s ordinal. Do not infer chronology from JSON
  object order.
- Optional web “current expedition” is community/web, never packed truth.

**Done when:** seasons and rewards flatten with stable order; history cannot
be mistaken for a live season.

## Slice 5 — Building catalog

**Data:** 1,654 parts, 1,571 requirement rows, 217 purchasable blueprint IDs.
Parts are not canonical products. Requirement materials are.

**Screens:** filtered parts, blueprint-available view, reverse “builds using
this material,” recorded-cost totals, saved material list.

**Rules:**

- Hide `NotEnabled` by default.
- Empty requirements means “not recorded,” never zero cost.
- 85 empty names stay empty; do not invent titles.
- Do not claim vendor, price, or ownership the pack does not have.
- Keep the source spelling `purchaseable_building_blueprints` as a
  compatibility alias.

**Done when:** all parts and requirement rows project; 217 blueprint IDs
match; unknown costs stay explicit.

## Slice 6 — Ship and corvette catalogs

### Ships

**Data:** 284 parts. No geometry, sockets, or compatibility graph.

**Rules:** Hauler / Fighter / Explorer / Solar are ship classes. Four
`Reactor` rows are a part kind, not a class. Unknown roles stay Unknown.
A saved configuration is a notebook, not a valid build.

### Corvettes

**Data:** 633 parts, 47 with requirements, 18 `WikiCategory == NotEnabled`.

**Rules:** Disabled only when that exact marker is true. Empty requirements
are “not recorded.” Composite categories need an explicit split policy.
No visual builder.

**Done when:** every record projects; the UI never treats missing
compatibility as approval.

## Later families

These stay behind the slices above unless a player job appears first.

### Rewards and special purchases

594 rewards and 332 purchases. Most join products. Reward sources are
many-to-many. Ten unnamed construction rewards link to both building and
corvette records — keep both. Do not label base value as a currency until
verified.

### Stories

7 categories, 40 pages, 592 entries. Preserve order and empty pages. Source
markup needs a safe renderer. Reading progress is a Slice 2 artifact.

### Fossils

143 records. Collection checklist only. No creature or set compatibility.

### Legacy

20 records: eight convert to `BAIT_BASIC` at ratio 10; twelve have no
conversion. Split those into conversion rules and tombstones.

## Promotion into the pack

Adding typed feature tables creates a new pack schema version. The app must
still open the previous compatibility payload until the new pack is
installed, then enable the specialist screen from the manifest capability
set. Release / rollback stays as it is today.

## Conversation follow-through (Slice 7)

After the planner and at least one specialist exist:

- Keep a short local conversation context (“scale that to 12”).
- Action cards open a typed workspace. They do not execute arbitrary SQL.
- Packed vs community/web badges only. No live-handbook badge.
- Structural claim validation is optional polish if narration starts
  inventing facts. It is not a prerequisite for the planner.

## Persistence

Slice 2 replaces direct `UserDefaults` artifact storage before the planner
ships. See [WORK_SLICES.md](WORK_SLICES.md). Export is a later user-initiated
share of an exact payload. Import is a separate untrusted-write feature.

## Quality for each specialist slice

- 100% of that family’s records decode or the pack build fails.
- Unknown enums and extra attributes survive projection.
- Database failure is an error, never an empty list.
- Airplane mode is enough. Do not add a hosted CI job to finish the slice.
- Run the new screen on the phone before calling it done.
