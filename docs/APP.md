# Atlas companion app

Atlas is an Apple-only No Man’s Sky pocket companion. The home screen is a
conversational Atlas, not a search bar. Canonical facts come from a pinned
local SQLite snapshot. Apple Foundation Models turn a question into tool calls
against that snapshot and present grounded cards. The internet is optional.

This document is the product contract for the first app screens. It does not
add typed fish, expedition, or ship-part tables. Those wait until a Library
screen needs them. `nms_content_records` remains the feature fallback.

Licensing posture is **internal until Phase 0 is written**. Do not ship
extracted images. Do not describe the app as a public or commercial release
until source code, structured game data, localization text, and images each
have an explicit publication decision. See [ROADMAP.md](ROADMAP.md) Phase 0
and the README source boundary.

## Outcome

A player can, with the network off and the asset pack on disk:

- Ask Atlas “what is Ferrite Dust for?” and get entity plus recipe cards.
- Open an item page and see craft-from / used-in recipes.
- Browse products, substances, technology, crafting, refining, and cooking.
- Bookmark items locally.

With the network on and the matching setting enabled, they can also:

- Query live Atlas tables when the pack is older than the active import.
- Search the web for patch notes, current expeditions, and wiki writeups.
  Web results are labeled community/web and never become an Atlas recipe.

## Tabs

1. **Atlas** — conversational composer, suggested chips, streaming reply,
   tappable cards.
2. **Library** — browse and keyword search over the local snapshot.
3. **Saved** — local bookmarks and recents. No user accounts in v1.
4. **Info** — local pack SHA, live SHA if reachable, Apple Intelligence
   availability, attribution, licensing notice, and network toggles.

## Screens

### Entity

Display `display_name`, then `name`, then `game_id`
([DATA_CONTRACT.md](DATA_CONTRACT.md)). Show type, category, subcategory,
rarity, legality, base value, subtitle, and description. Icons are type-colored
placeholders until the asset publication gate passes. Ignore
`icon_storage_path`.

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

Delivery:

- **Release:** Apple-hosted Managed Background Assets, download policy
  `essential` + `firstInstallation`. Pack ID is versioned by source commit.
  The main app reads the file through `AssetPackManager`.
- **Debug:** the same SQLite file from the app bundle or a generated preview
  fixture. `NMSStore` hides the difference.
- If the pack is missing, show a blocking “Preparing Atlas” progress state.
  Do not fall through to an empty UI or a required network fetch.

Dataset updates ship as a new asset pack, not as a full Data API download on
launch.

Live revision, when the user opts into live Atlas, is read from public row
provenance (`nms_entities.source_commit_sha`), not from `nms_private`.

## Atlas AI contract

The database knows NMS facts. The model does not. Foundation Models may only
state facts returned by tools. If tools miss, Atlas says so and offers local
search, plus live Atlas or web search when those settings are on.

Never present a web snippet as an Atlas recipe. If a web result disagrees with
local or live Atlas on items, recipes, or ingredients, Atlas states the packed
or live fact and marks the web result as community/web.

Instructions (session):

> You are Atlas, a No Man’s Sky reference assistant. You may only state facts
> returned by tools. If tools miss, say so. Never invent recipes, ingredients,
> or item stats. Never merge a web snippet into an Atlas recipe.

Guided intent kinds: lookup item, how to craft/refine/cook, what uses this,
browse category, ask the web, unknown.

Tools:

| Tool | Source | When |
|---|---|---|
| `search_entities` | local FTS5 | always |
| `get_entity` | local SQLite | always |
| `recipes_for` / `recipes_using` | local SQLite | always |
| `search_content` | packed feature JSON | always |
| `search_live_atlas` | Supabase anon `SELECT` | live Atlas setting on |
| `search_web` | keyless web fetch | internet search setting on |

UI: stream the spoken answer; durable UI is cards. Tapping a card opens the
native entity, recipe, or Safari view.

Suggested first chips:

- How do I cook food?
- What is Ferrite Dust for?
- Circuit Board recipe
- Refining Carbon
- Search the web (only if internet search is enabled)

### Fallback without Apple Intelligence

Foundation Models require Apple Intelligence on iOS/iPadOS/macOS 26
(iPhone 15 Pro and later, iPhone 16 and later, M1 and later). When
`SystemLanguageModel` is unavailable, the same composer runs local FTS5 and
shows the same cards, with a one-line note that Atlas chat needs Apple
Intelligence. Do not bundle MLX or another chat model to fake this.

## Optional internet

Off by default. Summarization stays on-device. The network only fetches.

**Live Atlas.** Same canonical tables as the pack, possibly a newer import.
Publishable key only. Chip: “Search live Atlas.”

**General web search.** For questions the snapshot is not supposed to answer
(current expedition, patch notes, wiki lore). First use confirms that the
query leaves the device. Chip: “Search the web.” Results are Web cards
(host, title, snippet, open in Safari). v1 fetches the NMS Fandom search API
and DuckDuckGo HTML as open-web fallback. No search-provider secret in the
IPA.

If the network fails, Atlas keeps using the pack. Quiet notes only: “live
Atlas unavailable” or “web search unavailable.”

## Attribution

Show on the Info tab and keep in the repository README:

- Structured data is transformed from
  [ApexFatality93/NMS-Handbook](https://github.com/ApexFatality93/NMS-Handbook)
  (GPL-3.0) at a pinned commit.
- Much of that text and imagery is extracted from No Man’s Sky and may contain
  rights owned by Hello Games or its licensors.
- Atlas-AI source code in this repository is separate from upstream generator
  code. Do not copy NMS-Handbook Python or website files into the app.
- Extracted images are not bundled. Placeholders stand in until Phase 0.

## Non-goals for v1

- Android, web, or a cloud LLM planner.
- Bundled on-device chat weights (MLX, llama.cpp, Core ML LLMs).
- User accounts, write APIs, or mutating game data.
- Image upload to Supabase Storage.
- Typed projections for fish, expeditions, ship parts, or building catalogs.
- Auto-updating the SQLite pack from `main` without a pinned commit.
