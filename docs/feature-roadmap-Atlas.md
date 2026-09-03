# Feature Roadmap — Atlas

**Date:** 2026-09-03
**App category:** Offline-first game reference companion
**Canonical work list:** [WORK_SLICES.md](WORK_SLICES.md)

## Current State

Atlas is a phone-local No Man's Sky companion that already builds and runs on
a physical device. Canonical facts come from a pinned SQLite pack:

- 2,597 entities
- 2,181 recipes
- 4,003 ordered ingredient rows
- 4,752 feature records
- 79,731 preferred localizations

The player can ask Atlas, browse Library, open entity/recipe/feature detail,
and bookmark items locally. Deterministic retrieval is authoritative. Apple’s
on-device system model may narrate those results; it is not a data source.
There is no cloud model.

A live internet handbook was an early idea. It is parked. Supabase is not
required to run the app. If a hosted snapshot is ever wanted, free Supabase
is enough. If custom user data later needs an account or another device, that
is a separate user-data backend (Supabase, Firebase, or similar).

One developer owns the repo. Local tests, local checkouts, and device runs
are the quality gate. Hosted CI is not a work item.

Attribution is already on the Info tab. Atlas transforms NMS-Handbook JSON
at a pinned commit, does not reuse that project’s Python, and does not claim
to own Hello Games material.

## Product promise

A player gets a trustworthy, actionable NMS answer from the phone, without
an account. The next differentiator is turning a desired item into a local
recipe plan.

## Work slices

Do these in order unless a specialist screen is suddenly more useful than a
planner. Details, files, and done checks are in [WORK_SLICES.md](WORK_SLICES.md).

| Slice | Job | Status |
|---|---|---|
| 0 | Align docs with the phone-local product | This pass |
| 1 | Recipe planner and local checklists | Next |
| 2 | Versioned local saved data (lists, notes, plans, progress) | Next, before more specialists |
| 3 | Fish and bait guide | Later |
| 4 | Expedition archive (historical only) | Later |
| 5 | Building catalog and material totals | Later |
| 6 | Ship and corvette catalogs (notebooks, not builders) | Later |
| 7 | Conversation follow-through into those workspaces | Later |
| 8 | Optional user-data sync | Only if another device or an account is wanted |

Specialist screen rules and source constraints live in
[SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md).

## Parked

| Item | Why it is parked |
|---|---|
| Live handbook API | The phone pack answers the product. Revisit only as a free Supabase snapshot. |
| Hosted CI | Solo development with local verification. |
| Extracted images | Placeholders are enough until you want icons. |
| Android or web | After the Apple companion is worth copying. |
| Second bundled model | Deterministic cards already work without Apple Intelligence. |
| Untrusted file import | Export first. |

## User-saved data

**Now:** Entity and recipe bookmarks plus recents in `UserDefaults`.

**Next (Slice 2):** Versioned local artifacts — bookmark, named list, note,
recipe plan, guide progress — with pack identity and a corrupt-file safe
store. Design the JSON so Slice 8 can upload it later.

**Optional later (Slice 8):** Account plus hosted user-data API. Sync only
player artifacts. The handbook stays on the phone.

## Quality

Keep the existing local gates:

- Python pack and pipeline tests
- iOS tests against the full pack and the disposable fixture
- `verify_ios_build.sh` when the Xcode project changes
- A device run for any player-visible slice

Do not add a GitHub Actions obligation to “finish” a slice.

## What would make this app great

Atlas feels like a trusted co-pilot beside the game: it answers immediately
offline, turns a desired item into a practical resource plan, remembers the
player’s lists, and never pretends a community snippet is a packed recipe.
