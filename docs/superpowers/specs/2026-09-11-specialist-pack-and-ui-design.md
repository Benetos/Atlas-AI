# Specialist pack v2 and usable feature UI

**Date:** 2026-09-11
**Status:** Approved direction for implementation
**Branch:** `cursor/specialist-pack-and-ui-9ba6`

## Goal

Players can find and use every packed feature family from Library and Atlas
before TestFlight. Projections exist so filters and facts are real. Screens
exist so people are not staring at JSON.

## Product

- Shared specialist shell: collection → filters → detail → compare or checklist.
- Richer Library: typed browse/filters for the same families, not raw payload.
- Cooking: first-class recipe-kind workspace on the existing planner.
- Ships/corvettes: parts catalog and notes. No assembly or compatibility claims.
- Expedition **archive UI** is deferred. Rows may still be packed.
- Icons: load referenced pack images. Fallback glyph only when the file is missing.
- Bait: show packed `UsedFor` (General / Day / Night / Storm) and rarity/size
  percents. No species-to-bait invention.

## Pack

- Schema version 2 only. There are no schema 1 users to migrate.
- Keep `nms_content_records` lossless.
- Additive typed tables projected from each content payload at SQLite build.
- Unknown fields stay in `extra_json`. Never drop a source field.
- Capability is schema 2. Do not keep a parallel schema 1 path.

## Non-goals

- Public App Store legal memo (owner already decided for this build).
- Species-specific bait not present in the table.
- Ship/corvette socket graphs.
- Expedition season archive screens.
