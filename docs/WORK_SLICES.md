# Atlas work slices

This is the current work list. Product decisions live in
[the slice design](superpowers/specs/2026-09-03-atlas-work-slices-design.md).
The companion contract is [APP.md](APP.md). Specialist screen rules stay in
[SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md).

Atlas is a **phone-local** No Man's Sky companion. The installed SQLite pack
is the handbook. The app already runs on a physical device. One developer
vets local checkouts before anything reaches GitHub.

```text
now:     phone pack -> ask / browse / bookmark
         optional web search for current / community questions
next:    recipe plans and richer local saved data
then:    typed guides from data already in the pack
later:   optional user-data sync (Supabase or Firebase)
parked:  live handbook API, hosted CI, extracted images
```

## Current foundation

Already true:

- Full pinned pack on device: 2,597 entities, 2,181 recipes, 4,003 ingredient
  rows, 4,752 feature records.
- Atlas, Library, Saved, and Info tabs.
- Deterministic query planner for the advertised questions.
- Optional on-device narration with an eight-second fallback to the SQLite
  answer.
- Local bookmarks and recents in `UserDefaults`.
- Optional internet search for questions the pack cannot answer or that need
  current community information. Results are labeled community/web.
- Release pack download, verify, activate, and rollback code. Debug embeds
  the full pack.

Not current product:

- A live internet copy of the handbook. `LiveAtlasClient` is leftover from
  that idea. Web search is not that path.
- Accounts, cloud save, or a second backend.
- Typed fish, expedition, building, or ship workspaces. Those families open
  as generic content records today.

## Slice 0 — Tell the truth in the repo

**Job:** Make docs and leftover UI match the phone-local app.

**In**

- Park live Atlas in product copy. Keep the client only as unused leftover
  or delete it in a later cleanup.
- Say user data is local now, with optional hosted sync later.
- Drop hosted CI and licensing theater as open work.

**Out**

- Building a live handbook API.
- Rewriting the pack pipeline.

**Done when:** README, APP, roadmaps, and Info copy describe the app that
runs on the phone.

**Status:** This documentation pass.

## Kept — optional web augment

**Job:** Help when the player is outside the pack or needs current
community information.

This is not a second database. The pack still answers items, recipes, and
packed history. Web search is for the rest: a new expansion, patch notes,
what expedition is active, good YouTube videos, wiki lore the snapshot was
never meant to own.

**Already in the app**

- Off by default. First use asks before a query leaves the device.
- Explicit “search the web” intent, or time-sensitive words plus expedition /
  patch / update language.
- Fandom search plus DuckDuckGo HTML. Web cards open in Safari.
- A local miss does not automatically go online.

**Later polish, not a prerequisite for the planner**

- Clearer “this is not in the pack — search the web?” when the question is
  current news, video, or community opinion.
- Keep the packed answer on screen when both exist.
- Prefer video hosts when the player asks for videos.

**Out**

- Downloading handbook tables from the internet.
- Merging a web snippet into a recipe or item stat.
- Requiring the network for Atlas, Library, or Saved.

## Slice 1 — Recipe planner

**Job:** “I need 12 Circuit Boards” becomes a local checklist.

**Why first:** The recipe graph is already packed. This is the first feature
that is more than a handbook in a nicer shell.

**In**

- Quantity, alternate craft/refine/cook paths, cycle detection, totals.
- Save the plan as a local checklist with progress.
- Atlas can open a plan from a recipe question.
- Deterministic engine. The model may explain options; it does not invent
  ingredients.

**Out**

- Inventory sync from the game.
- Cloud save.
- Building-part material plans (Slice 5).

**Done when:** Known multi-step fixtures produce exact totals; cycles do not
hang; a saved plan restores after relaunch and records which pack created it.

**Files:** `SQLiteNMSStore` recipe graph, new planner types, Atlas/Library
actions, Saved tab.

## Slice 2 — Local saved-data model

**Job:** Player work survives relaunch in a store that can sync later.

**Why here:** The planner should not write another `UserDefaults` blob.
Specialist slices will need lists, notes, and progress too.

**In**

- Versioned local artifacts: bookmark, list, note, recipe plan, guide
  progress.
- Atomic file store in Application Support, with checksum and quarantine of
  a corrupt file.
- Idempotent migration from today’s bookmark/recents keys.
- Pack release recorded on each artifact. A pack change does not silently
  rewrite a plan.

**Out**

- Accounts.
- Import of untrusted shared files.
- Choosing Supabase vs Firebase. That is Slice 8.

**Done when:** Bookmarks migrate once without duplicates; a plan and a named
list survive relaunch and a simulated corrupt file; schema version is
explicit.

**Later hook:** Artifact payloads should be JSON the optional sync slice can
upload unchanged.

## Slice 3 — Fish and bait guide

**Job:** Filter fish by biome, time, and conditions; compare bait honestly.

**In**

- Typed projection of the 226 fish and 621 bait records already in the pack.
- Faceted list, detail, and condition-aware bait comparison.
- Local “caught / want” progress using Slice 2 artifacts.

**Out**

- Species-specific bait claims. The source is condition-based only.
- A single invented bait rank.

**Done when:** Every fish and bait record projects; canonical links resolve;
missing size or description shows “not recorded.”

## Slice 4 — Expedition archive

**Job:** Browse historical seasons and reward groups.

**In**

- 21 packed seasons and ordered reward groups.
- Local owned/wanted tracking.
- Clear **Historical** label.

**Out**

- “Current expedition” from the pack. The source has no dates or
  availability.
- Live or web status unless the player later asks the optional web path.

**Done when:** Seasons and rewards flatten with stable order; packed history
cannot be mistaken for a live season.

## Slice 5 — Building catalog and material totals

**Job:** “What can I build with Ferrite Dust?” and a parts checklist.

**In**

- Filtered parts, blueprint membership, reverse material lookup.
- Totals only where requirements are recorded.
- Saved material list via Slice 2.

**Out**

- Vendor prices or ownership the pack does not have.
- Treating an empty requirement list as zero cost.

## Slice 6 — Ship and corvette catalogs

**Job:** Browse and note parts. Do not pretend the app can validate a ship.

**In**

- Class/role catalogs, detail, comparison, saved configuration notebook.
- Missing compatibility shown as missing, never as “fits.”

**Out**

- Visual builders, sockets, or geometry. The pack does not have them.

## Slice 7 — Conversation follow-through

**Job:** Atlas opens the slices above instead of only returning cards.

**In**

- Follow-up turns against the last local result (“scale that to 12”).
- Action cards: open planner, open fish filter, save to a list.
- Packed vs community/web badges. No live-handbook badge.
- Offer web search when the question is current news, video, or otherwise
  outside the pack — still labeled community/web.

**Out**

- Cloud model fallback.
- Evidence-ledger architecture as a prerequisite. Add structural claim
  checks only if narration starts inventing facts players notice.

## Slice 8 — Optional user-data sync

**Job:** Lists, plans, and notes appear on another device, or behind an
account.

**When:** Only after local saved data is something the player would miss.

**In**

- Pick one hosted user-data backend: free Supabase, Firebase, or similar.
- Account, upload/download of Slice 2 artifacts, last-write-wins per
  artifact.
- Offline-first: the phone store remains usable with the network off.

**Out**

- Hosting the handbook. If a public snapshot is ever wanted, that is a
  separate parked idea on free Supabase, not this slice.
- Syncing prompts, model output, or the SQLite pack.

**Done when:** A plan created on the phone round-trips through the backend
and reopens as the same artifact; airplane mode still reads the local copy.

## Parked

Do not schedule these unless the product question changes:

| Parked | Why |
|---|---|
| Live handbook API | Phone pack is enough. Revisit only as a free Supabase snapshot. |
| Hosted CI | Solo development; local tests and device runs are the gate. |
| Extracted images | Placeholders are fine. Add icons only if you want them. |
| Android or web | After the Apple companion is the product you want to copy. |
| Second bundled model | Deterministic cards already work without Apple Intelligence. |
| Untrusted file import | Export first; import is a separate untrusted-write feature. |

## How to pick the next slice

Work Slice 1, then 2, unless a specialist screen is suddenly more useful
than a planner. Do not start Slice 8 to “get the backend ready.” Do not
reopen live Atlas to make Library feel more complete.
