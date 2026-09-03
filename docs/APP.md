# Atlas companion app

Atlas is an Apple-only No Man’s Sky pocket companion. The home screen is a
conversational Atlas, not a search bar. Canonical facts come from a pinned
local SQLite snapshot. Apple’s on-device `SystemLanguageModel.default` may
interpret and narrate answers grounded in that snapshot. All language-model
inference stays on the device: Atlas never sends prompts, evidence, or model
output to a cloud model. The app remains useful without the model. The
internet is optional and is not used for the handbook. Every database
capability used to answer, search, browse, or navigate executes against the
installed on-device SQLite pack.

This document is the product contract. Work is sliced in
[WORK_SLICES.md](WORK_SLICES.md). Typed fish, expedition, and ship-part
screens are later slices. `nms_content_records` remains the compatibility
fallback until those families are promoted. Screen and source-data rules for
those slices are in
[SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md).

A live internet copy of the handbook is **parked**. It was an early idea and
is not part of the current product. If it returns, it would be a free
Supabase snapshot, not the thing the app queries for answers.

User-saved data is **local**. Bookmarks and recents already live on the
device. Lists, plans, notes, and progress should too. If custom user data
later needs an account or another device, the backend can be Supabase,
Firebase, or similar. That slice syncs player artifacts only.

Atlas transforms NMS-Handbook JSON at a pinned commit. It does not reuse
that project’s Python or website, and it does not claim to own Hello Games
material. Attribution stays on the Info tab. Extracted images are not
bundled.

## Outcome

A player can, with the network off and the asset pack on disk:

- Ask Atlas “what is Ferrite Dust for?” and get entity plus recipe cards.
- Open an item page and see craft-from / used-in recipes.
- Browse products, substances, technology, crafting, refining, and cooking.
- Bookmark items locally.

With the network on and internet search enabled, they can also:

- Ask Atlas about things the pack cannot own: a new expansion, patch notes,
  the current expedition, community writeups, or good videos.
- Get **Web cards** (host, title, snippet, open in Safari). Those results
  are labeled community/web and never become an Atlas recipe or item stat.

A hosted handbook comparison (“live Atlas”) is leftover code, not a current
player feature. Web search is the only intended network augment.

## Tabs

1. **Atlas** — conversational composer, suggested chips, grounded reply,
   tappable cards.
2. **Library** — browse and keyword search over the local snapshot.
3. **Saved** — local bookmarks and recents. No user accounts in v1.
4. **Info** — local pack SHA, on-device model availability, attribution,
   and optional internet-search toggle.

## Screens

### Entity

Display `display_name`, then `name`, then `game_id`
([DATA_CONTRACT.md](DATA_CONTRACT.md)). Show type, category, subcategory,
rarity, legality, base value, subtitle, and description. Icons are type-colored
placeholders. Ignore `icon_storage_path`.

Lists:

- Recipes that output this entity.
- Recipes that consume this entity.

### Recipe

Kind (crafting / refining / cooking), output amount, time, ordered ingredients
with amounts, and links to each entity. Reverse navigation goes to the output
item.

### Search results

Shared by Atlas fallback and Library. Rows are entities, recipes, or feature
content records. Web hits use a distinct **Web card** and must not reuse
entity/recipe chrome.

## Data: local pack first

The app does not need Postgres to answer “what is Ferrite Dust” or “how do I
cook this.” Those answers live in a versioned SQLite pack built from the
transform CSVs by `scripts/build_nms_sqlite.py`.

Packed tables:

- `nms_entities` plus FTS5 over name, subtitle, and description.
- `nms_recipes` and `nms_recipe_ingredients`.
- Preferred `nms_localizations` rows only.
- `nms_content_records` including payload JSON.
- Manifest: source commit, contract version, counts, file SHA-256.

Not packed: private lossless `source_records`, image blobs, or service-role
data.

### On-device database execution contract

“Database capability” includes deterministic pre-retrieval, Library and detail
queries, and every callable tool registered with an on-device model planner. All of
them execute inside the app and read only the installed, verified SQLite pack.
They do not call Postgres, Supabase, an HTTP API, or a remote function.

The production model-tool registry has one concrete dependency:
`SQLiteNMSStore`. A database tool may not receive `AppSettings`, `URLSession`,
`LiveAtlasClient`, `WebSearchClient`, a URL, or credentials. The store opens the
pack read-only. A missing, corrupt, or incompatible pack fails closed to the
pack error/retry state; a database error or zero-result query never triggers an
automatic network fallback.

The production pack must contain every table, index, payload, and preferred
localization needed by the supported database capabilities. The three-entity
fixture is bundled only with `AtlasTests` for focused mutation and corruption
tests; it is not an app runtime fallback and must never satisfy the Debug or
Release app gate. Pack delivery may download an immutable asset from Apple, but verification,
activation, all SQL execution, search, joins, and model tool calls occur on the
device. Updates replace the verified local snapshot rather than changing query
execution to a hosted database.

Delivery:

- **Release target:** Apple-hosted Managed Background Assets, download policy
  `essential` + `firstInstallation`. The pack keeps a stable ID while its
  archive and embedded manifest are pinned to a source commit. An embedded
  StoreKit downloader extension obtains the pack through `AssetPackManager`.
  Atlas copies the process-scoped files into app-owned staging, verifies the
  sidecar SHA-256/size/schema/provenance/counts plus SQLite quick/FK/FTS and
  read-only boundaries, moves the immutable release into place, then atomically
  flips a small active/previous pointer. A corrupt active release is replaced
  automatically by the prior verified copy.
- **Debug:** the complete ignored `build/nms-sqlite` production pair is bundled
  for simulator work and hosted integration tests. Preparing the full pinned
  pack is a build prerequisite; missing files fail clearly instead of opening a
  misleading partial catalog. Both bundled files are excluded from Release.
- If the pack is missing, show a blocking preparation/error state with retry.
  Download, verification, and activation progress are shown. Do not fall
  through to an empty UI or substitute a remote database.

Dataset updates ship as a new asset pack, not as a full Data API download on
launch.

There is no runtime live-revision check in the current product. Pack
identity is the local manifest.

## Atlas AI contract

The installed database knows NMS facts. The model does not. Today,
deterministic SQLite retrieval, templated summaries, and native cards are the
authoritative output. The on-device model is instructed to narrate only those
local results, but the structural evidence ledger and claim validation that can
prove every generated factual statement are beta targets, not current runtime
guarantees. Generated prose is therefore presentation, not a canonical fact
source. A local miss or database failure never silently escalates to a network
source.

### Runtime policy and provider order

Language-model inference is an on-device capability, not a network service:

1. **Primary for v1:** Apple’s on-device `SystemLanguageModel.default`, when
   its runtime availability check succeeds. It interprets the goal, chooses
   among approved local read tools, and proposes evidence-bound response and
   action plans inside deterministic policy.
2. **Required fallback:** the deterministic query planner, local SQLite
   retrieval, templated narration, and native cards. This path requires no
   model and must remain a complete offline reference experience.
3. **Optional later provider:** a separately evaluated bundled Core AI/Core ML
   model behind the same `AtlasModelPlanning` boundary, only if beta evidence
   shows that generative behavior is required on unsupported hardware.
4. **Forbidden fallback:** Apple Private Cloud Compute and third-party cloud
   model APIs. Atlas does not add a remote model when the system model is
   unavailable.

The target generative-to-native pipeline is:

```text
prompt -> deterministic policy envelope
                   |- on-device model agent -> approved local read tools -|
                   `- deterministic planner -----------------------------|
                                                                         v
                                                                  EvidenceLedger
                                                                         |
                                                               ProposedTurnPlan
                                                                         |
                                                        validator + native renderer
                                                                         |
                                                  grounded blocks/cards + actions
```

The model session receives the fixed local tool registry, not network clients,
settings, arbitrary SQL, or mutating services. In the beta target architecture,
generated claims and actions carry evidence IDs; invalid or unknown IDs cause
deterministic rendering from the same local evidence instead of being shown or
executed. That structural validation is not implemented for current generated
prose. The current `AtlasQueryPlan`, SQLite results, templated summary, and
cards remain the authoritative deterministic path and supply source-policy
signals until those checks move into a dedicated envelope.

Never present a web snippet as an Atlas recipe. If a web result disagrees with
the packed handbook on items, recipes, or ingredients, Atlas states the packed
fact and marks the web result as community/web.

Instructions (session):

> You are Atlas, a No Man’s Sky reference assistant. You may only state facts
> returned by tools. If tools miss, say so. Never invent recipes, ingredients,
> or item stats. Never merge a web snippet into an Atlas recipe.

Guided intent kinds: lookup item, how to craft/refine/cook, what uses this,
browse category, explicitly ask the web, unknown. Live-handbook intent is
parked and must not leave the device.

### Model-callable database tools — all on-device

| Tool | Source | When |
|---|---|---|
| `search_entities` | installed SQLite FTS5 | always |
| `get_entity` | installed SQLite | always |
| `recipes_for` / `recipes_using` | installed SQLite recipe graph | always |
| `search_content` | installed SQLite FTS5 + packed payload JSON | always |

`LocalDatabaseToolRegistry` is the fixed production allowlist. The model
session explicitly uses `SystemLanguageModel.default`, and the registry can be
constructed only from `SQLiteNMSStore`.

### Controller-only optional retrieval — never model tools

| Operation | Network source | Gate |
|---|---|---|
| Web lookup | public web fetch | per-source intent and consent |
| Live handbook comparison | parked | do not use |

Web lookup remains outside the model and database-tool dependency graph.
Results are provenance-tagged supplemental cards, are never silently folded
into canonical recipes, and never substitute for a local miss or failure.
The leftover live-Atlas client is not a player feature.

The UI waits up to eight seconds for a concise on-device narration grounded
in the SQLite result, then returns one answer with the authoritative cards.
If the model fails or reaches that bound, Atlas returns the verified
deterministic database answer instead of hanging. Persistent model sessions,
streaming, and evidence-linked generated output are later conversation work,
not a prerequisite for the planner.

Durable UI is cards. Tapping a card opens the native entity, recipe, feature
record, or Safari view.

Suggested first chips:

- How do I cook food?
- What is Ferrite Dust for?
- Circuit Board recipe
- Refining Carbon
- Search the web (only if internet search is enabled)

### Fallback when the system model is unavailable

Atlas checks `SystemLanguageModel.default` at runtime rather than maintaining a
hard-coded device list. The model may be unavailable because the device is not
eligible, Apple Intelligence is disabled, the model is not ready, or the
current language/locale is unsupported. In every case, the same composer runs
the deterministic local planner and SQLite search, then shows grounded text and
the same native cards. The UI explains the specific reason when the API exposes
one; it never suggests that network access is required.

A bundled alternative model is a deliberate post-beta product decision, not an
automatic fallback. It must meet agreed app-size, memory, latency, thermal,
device-coverage, model-license, and update-policy budgets before adoption.

## Optional internet

Off by default. Model inference and database tools always stay on-device. Only
an enabled request with explicit web source intent sends a search query over
the network; no prompt, local evidence bundle, or model output is sent to a
remote model service. A local miss does not count as source intent.

**Live handbook.** Parked. Do not query Supabase for answers. Leftover
`LiveAtlasClient` code is not product.

**General web search.** An optional augment, not a second handbook. Use it
when the player is outside the pack or needs current community information:
a new expansion, patch notes, the live expedition, wiki lore, or videos.
First use confirms that the query leaves the device. Chip: “Search the web.”
Results are Web cards (host, title, snippet, open in Safari). v1 fetches the
NMS Fandom search API and DuckDuckGo HTML as open-web fallback. No
search-provider secret in the IPA. A local miss is not consent to go online.

If an explicitly requested network operation fails, Atlas keeps using the pack.
Quiet note only: “web search unavailable.”

## User-saved data

v1 saves entity and recipe bookmarks plus recents on the device. The next
saved-data slice adds versioned local artifacts (lists, notes, recipe plans,
guide progress) so a later optional sync backend can upload the same JSON.
See [WORK_SLICES.md](WORK_SLICES.md) Slices 2 and 8.

## Attribution

Show on the Info tab and keep in the repository README:

- Structured data is transformed from
  [ApexFatality93/NMS-Handbook](https://github.com/ApexFatality93/NMS-Handbook)
  JSON at a pinned commit. Atlas does not reuse that project’s Python or
  website.
- Atlas does not claim to own Hello Games material. Placeholders stand in
  for extracted images.
- Attribution stays on the Info tab.

## Non-goals for v1

- Android or web clients.
- Cloud language-model inference of any kind, including Apple Private Cloud
  Compute or third-party model APIs.
- Remote execution or automatic network fallback for any database capability
  used by Atlas, Library, Saved, or detail screens.
- Shipping a second bundled model before beta device-coverage evidence shows
  that the deterministic fallback is insufficient.
- User accounts or a hosted user-data API until Slice 8 is explicitly started.
- A live internet handbook or any automatic network fallback for answers.
- Image upload to object storage.
- Typed projections for fish, expeditions, ship parts, or building catalogs
  before their slices.
- Auto-updating the SQLite pack from `main` without a pinned commit.
