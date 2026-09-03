# Atlas work-slice design

**Date:** 2026-09-03
**Status:** Current product direction
**Related:** [WORK_SLICES.md](../../WORK_SLICES.md), [APP.md](../../APP.md),
[feature-roadmap-Atlas.md](../../feature-roadmap-Atlas.md)

## Product

Atlas is a phone-local No Man's Sky companion. The installed SQLite pack is
the handbook. The app already builds and runs on a physical device. There is
one developer; local checkout and device runs are the quality gate.

Canonical facts come from the pinned pack. The on-device system model may
narrate those facts. It is not a source of game data. There is no cloud model
and no live internet handbook in the current product.

## Decisions already made

1. **The phone is the database.** Debug embeds the full pinned pack. Release
   can still deliver that pack as an Apple-hosted Background Asset. Neither
   path queries Postgres to answer a player.
2. **Live Atlas is parked.** A hosted copy of the handbook was an early idea.
   It is not worth running now. If it comes back, free Supabase is enough,
   because it would only be a published snapshot.
3. **User data stays local until sync is a real need.** Bookmarks and recents
   already live on the device. Lists, plans, notes, and progress should too.
   If custom user data later needs an account or another device, the backend
   can be Supabase, Firebase, or similar. That is a new product, not a second
   handbook.
4. **Attribution, not ownership.** Structured data is transformed from
   NMS-Handbook JSON at a pinned commit. Atlas does not reuse that project's
   Python or website. The app attributes the source and does not claim to own
   Hello Games material. Other community references already exist. Licensing
   theater is not a work item.
5. **No hosted CI obligation.** Nothing reaches GitHub without a local test
   and a vetted checkout.

## What "a slice" means

A slice is one player-visible job that can ship on the phone by itself.

- It has a user job, a local data source, screens or cards, and a done check.
- It does not require accounts, a live database, or a second platform.
- It can save player work locally in a versioned artifact the later sync
  slice can upload without rewriting the feature.
- It keeps a deterministic path: no model required.

## Recommended order

| Slice | Job | Why this position |
|---|---|---|
| 0 | Align docs and leftover live-Atlas surface with the phone-local product | Stops the repo describing a product that is not shipping |
| 1 | Recipe planner and local checklists | Highest-value use of data already on the phone |
| 2 | Local saved-data model: lists, notes, plans, progress | Unlocks planner and specialist slices without a backend |
| 3 | Fish and bait guide | Strongest typed feature family in the pack |
| 4 | Expedition archive | Historical seasons and rewards; never "current" |
| 5 | Building catalog and material totals | Reverse lookup from items the player already has |
| 6 | Ship and corvette catalogs | Notebooks, not visual builders |
| 7 | Conversation follow-through | Atlas can open the slices above; still local |
| 8 | Optional user-data sync | Only if another device or an account is wanted |

Parked on purpose: live handbook API, hosted CI, extracted images, Android or
web, a second bundled model, and public-store paperwork until a store build
is actually needed.

## User-saved data

### Now

`SavedStore` keeps entity and recipe bookmarks plus recents in `UserDefaults`.
That is enough for v1 bookmarks. It is not enough for plans, lists, notes,
or pack-aware progress.

### Next local model

Replace ad-hoc defaults with one versioned local artifact store before the
planner ships:

- bookmarks (entities, recipes, later feature records)
- named lists
- recipe-plan checklists
- specialist progress (owned rewards, reading position)
- freeform notes attached to a record or list

Each artifact records its schema version, kind, stable ID, and the pack
release it was created against. A pack update never silently rewrites a
plan. Recompute is an explicit preview.

### Later optional sync

If player data should leave the phone:

- Keep the same local store as source of truth while offline.
- Add an account and a hosted user-data API (Supabase, Firebase, or similar).
- Sync only user artifacts. Never upload the handbook, prompts, or model
  output as the canonical database.
- Conflict policy is last-write-wins per artifact until a real multi-device
  user appears.

This slice is optional. Do not build the backend "just in case."

## Non-goals for the current stream

- Querying Supabase for handbook answers
- Turning leftover `LiveAtlasClient` into a product
- GitHub Actions as a substitute for local verification
- Claim-validated generative architecture before the planner exists
- Importing untrusted shared files before export even exists
