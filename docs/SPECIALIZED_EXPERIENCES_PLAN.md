# Specialized Experiences Implementation Plan — Atlas

**Date:** 2026-09-01
**Status:** Proposed implementation direction; specialist engineering not started
**Scope:** Generative Atlas, native specialist workspaces, on-device tools,
typed feature projections, saved artifacts, and the shared interaction shell
**Related:** [APP.md](APP.md), [DATA_CONTRACT.md](DATA_CONTRACT.md),
[feature-roadmap-Atlas.md](feature-roadmap-Atlas.md)

## Outcome

Atlas remains a generative, conversational product. The user should be able to
describe a goal in ordinary language, get a grounded answer, and move into the
right purpose-built workspace without manually reconstructing the answer in a
generic database browser.

The core loop is:

```text
ask Atlas -> inspect grounded evidence -> take a native action -> save progress
```

Examples:

- “I need 12 Circuit Boards” opens a quantity-aware recipe plan.
- “What can I catch at night on a frozen planet?” opens a pre-filtered fish
  guide and offers a comparison of recorded night-bait bonuses.
- “Show Fighter cockpit parts” opens a ship-parts catalog with supported
  class and component-role filters.
- “What did Expedition 12 reward?” opens the packed historical season and
  ordered reward-group archive.
- “What can I build with Ferrite Dust?” opens reverse building-material
  results and can create a material checklist.

The model does not generate arbitrary SwiftUI, execute SQL, invent navigation
targets, or become the source of game facts. It interprets the request, selects
approved local read capabilities, and proposes actions inside an app-owned
policy, evidence, and routing envelope.

## Starting Point

The repository already has the right seeds: four primary tabs; typed entity,
recipe, and generic-content routes/cards; a working local SQLite store; a fixed
five-tool local registry; Apple system-model and deterministic response paths;
pack readiness/rollback; Library search; and local entity/recipe bookmarks.

The specialized interface is not implemented yet:

- `AtlasView`, `LibraryView`, and `SavedView` own separate navigation stacks and
  duplicate destination rendering; cross-section deep links and restoration do
  not have one source of truth.
- Each send creates a new session/controller, so follow-ups, cancellation, and
  stale-turn protection are incomplete.
- Model output is prose/cards rather than a validated evidence/claim/action
  plan, and tool outputs do not yet carry complete evidence/provenance types.
- Feature families open a generic payload detail with raw JSON rather than
  typed filters, comparisons, planners, guides, or configurations.
- `SavedStore` persists only entity/recipe records through `UserDefaults`; it
  cannot safely version plans, progress, configurations, or pack staleness.
- Swift tests cover core retrieval and pack behavior, but not centralized
  routes, adaptive presentation, saved-artifact recovery, action policy, or
  complete generative-to-native flows.

This plan extends those foundations rather than replacing the existing app.

## Product Decisions

These decisions are the foundation of the implementation:

1. **Atlas is the front door.** The Atlas tab remains the default experience.
   Library, Saved, and Info remain first-class destinations, not separate
   products.
2. **Generated answers lead to native workspaces.** Conversation is best for
   intent and explanation; native screens are best for dense comparison,
   filtering, planning, progress, and direct manipulation.
3. **The model proposes; the app validates and executes.** Facts come from an
   evidence ledger. Routes and actions come from closed, typed allowlists.
4. **Canonical capabilities remain fully on-device.** The production model
   registry reads the installed SQLite pack only. There is no cloud-model or
   hosted-database fallback.
5. **Every supported workflow has a deterministic path.** A user on a device
   without the Apple system model still gets the same records, cards, actions,
   and specialist screens.
6. **Specialized screens require typed contracts.** Raw content JSON remains a
   compatibility and diagnostic fallback; it is not the long-term screen API.
7. **Writes remain app-owned.** Saving a plan, changing guide progress, or
   deleting an artifact is never a model tool. A generated write proposal is
   confirmed and revalidated before execution.
8. **Capabilities must match the data.** Atlas must not claim current
   expedition status, bait-to-species affinity, ship-part compatibility, or
   corvette connection validity when the packed source does not provide those
   facts.

### Explicit non-goals for the first specialist releases

- Arbitrary model-generated interfaces or executable UI descriptions.
- A remote LLM, Private Cloud Compute, or remote canonical database queries.
- A visual ship/corvette assembly system before geometry, socket, orientation,
  and compatibility data are available and validated.
- Extracted game imagery before the publication and licensing gate passes.
- “Current expedition” claims derived from the historical pack, which contains
  no dates or availability state.
- Species-specific bait claims; the source records condition-level bait effects
  only.

## Experience Architecture

```text
User turn + bounded validated context
                 |
                 v
         SourcePolicyDecision
 (allowed sources, consent, capability bundle)
                 |
        on-device model planner
       (pack + capability keyed session)
                 |
                 v
      approved local knowledge tools
        |- bounded SQLite reads
        `- bounded pure calculations
                 |
                 v
      EvidenceLedger + ProposedTurnPlan
                 |
        claim validator / action resolver
                 |
        +--------+----------------+
        |                         |
 grounded native renderer   ActionPolicyDecision
                                  |
                         router / PendingAction
                                  |
                                  v
                     native specialist workspace

Model unavailable / timeout / refusal / invalid arguments or output
                 -> DeterministicPlanner -> same ledger/plan/renderer

Database or pack failure -> explicit local error (never network fallback)
```

Live Atlas and web retrieval remain separate controller-owned branches. The
model may propose an external search, but only deterministic source policy and
one-shot query-specific consent can authorize it. A consent receipt binds the
source, normalized outbound query, originating turn, and expiry. A global
setting enables the capability but does not authorize a request. Outbound text
must derive from the user's text or an app-owned rewrite—not database content or
an unconstrained model string. Only a URL in fetched `WebEvidence` may open.

### Core contracts

| Contract | Responsibility |
|---|---|
| `SourcePolicyDecision` | Determine allowed local/live/web sources, exact consent state, and safe capability bundle before model planning. |
| `AtlasIntent` | Represent lookup, browse, compare, calculate, plan, guide, configure, save, remove, and clarification semantics without granting authority. |
| `EvidenceBundle` | Hold bounded typed records, snapshot-scoped evidence IDs, source, pack release, and source commit for one turn. |
| `EvidenceLedger` | Resolve current and explicitly retained evidence; reject unknown or stale IDs. |
| `DerivedEvidence` | Record pure engine name/version, normalized inputs/bounds, ordered parent evidence IDs, pack release, output, and result digest for calculations/comparisons. |
| `ProposedTurnPlan` | Let the on-device model select closed claim kinds, `FactRef`s, typed follow-up intents, and unresolved action proposals. |
| `ClaimValidator` | Reject unsupported claim kinds, wrong/unknown/stale facts, altered quantities, and invalid derived-evidence ancestry. |
| `ActionResolver` | Convert a proposal into a resolved action only after validating record IDs, facets, quantities, query bounds, source mapping, and current pack capability. |
| `ActionPolicyDecision` | Allow, deny, or require confirmation after the exact action has been resolved. |
| `ValidatedAssistantTurn` | Supply only grounded message blocks, sourced cards, notices, and resolved action cards to SwiftUI. |
| `AtlasAction` | Closed action enum for open, filter, compare, plan, guide, configure, save, export, or request-external-source. |
| `AppDestination` | Versioned, bounded routes containing trusted record/artifact IDs or typed queries rather than evidence IDs, rows, prose, or arbitrary dictionaries. |
| `FeatureCapabilityRegistry` | Map a manifest capability to its typed repository, presenter, routes, action resolver, and bounded domain-tool bundle. |
| `SavedArtifact` | Versioned local bookmark, recipe plan, configuration, guide progress, or comparison preset with pack identity. |
| `PendingAction` | Bind a resolved write, turn, evidence digest, pack release, issued/expiry time, single-use nonce, and consumed state for confirmation/execution. |

Evidence IDs are issued by app code from source identity, record key, and a
payload digest. They are never invented by the model and are valid only for the
matching content snapshot. Deep links and saved artifacts persist trusted
record keys plus pack/capability identity, not evidence IDs. Packed and external
records do not collapse into one route without an explicit canonical mapping.

The proposed plan is not UI-ready truth. Initial releases allow only closed
`ClaimKind` values referencing exact `FactRef`s; the grounded native renderer
writes every factual sentence from evidence. Generated language may provide
non-factual transitions or tone, but arbitrary generated factual prose is not
displayed. Unsupported claim shapes use the deterministic plan/renderer.
Calculated facts such as recipe totals and material summaries use
`DerivedEvidence` and display “Calculated from pack …” instead of merely
“Packed.” Generated follow-ups are typed intents with app-rendered labels; they
are never arbitrary prompt text that auto-submits, starts networking, or writes.

The generated-action boundary is always:

```text
GeneratedActionProposal -> ActionResolver -> ResolvedAction
                                          -> router or PendingAction
```

### Conversation behavior

- Keep app-owned conversation context across turns. The engine actor owns a
  model session keyed by `(packReleaseID, capabilityBundleID)` and recreates and
  reseeds it whenever either value changes, because a Foundation Models
  session's tool set is fixed at construction.
- Keep a bounded app-owned context: validated recent turns, focused record
  keys, current goal/preferences, action outcomes, and active pack release.
- A compact generated summary can preserve conversational tone but cannot
  supply facts without retained evidence.
- Beta conversation history is scene-memory only and does not survive relaunch.
  The live model session is never serialized. Future transcript persistence
  requires a separate versioned schema and privacy review.
- Reset evidence/tool context and cancel in-flight conversation, collection,
  detail, and planner tasks when the active pack changes. Historical cards may
  remain visible with their old release label, but their actions are disabled
  as “Refresh required” until re-resolved against the new pack. Follow-ups
  re-query the active release.
- Use generation IDs and cancellation so a late response cannot append after a
  newer request.
- Stream neutral progress if useful, but do not make factual blocks or actions
  interactive before final validation.
- Resolve “that one” only against app-owned focus. Multiple valid referents
  produce clarification chips instead of a guess.

## Navigation and Shared Interface System

### Application shell

Keep the existing four primary destinations:

- **Atlas:** generative home, conversation history, grounded result and action
  cards.
- **Library:** direct search, browse, typed collections, and manual entry into
  the same specialist workspaces.
- **Saved:** bookmarks, plans, configurations, guide progress, and comparison
  presets.
- **Info:** pack identity, model availability, privacy, source controls,
  attribution, licensing, and diagnostics.

Replace the three view-owned destination switches with one shared destination
renderer and a scene-local, `@MainActor` `AtlasRouter`. Its source of truth is:

- `selectedSection`;
- one typed `[AppDestination]` path for each section; and
- per-section regular-width content/detail selection.

Compact `TabView`/navigation stacks and regular-width
`NavigationSplitView` are projections of that same state, selected by available
width/size class rather than device name. An action crossing sections first
selects the target section and then appends to that section's retained path; the
source path remains intact. App-wide pack, settings, and saved services do not
belong in the scene router.

`AppDestination` is wrapped in a versioned route envelope with bounded Codable
query values. It never contains arbitrary filter dictionaries, full database
records, model prose, or a planner graph. A persisted `SavedArtifactID` is a
durable/restorable route. An unsaved plan/configuration uses a scene-local draft
ID and draft store and is not encoded for restoration. The destination renderer
uses a feature-model factory; it does not query repositories itself.

If a visible target is deleted, its capability becomes unavailable, or the app
rolls back to a pack that cannot resolve it, show a typed unavailable/stale
state with Back, Refresh/Re-resolve, and Delete Stale Reference as appropriate.

### Answer anatomy

Every completed Atlas answer should use the same hierarchy:

1. A concise grounded answer or explicit no-match explanation.
2. A small result deck with the most relevant records.
3. One primary action that advances the likely job.
4. Zero to two secondary actions, such as compare, filter, or save.
5. Visible source and pack provenance without requiring the user to open Info.

Do not turn every answer into a dashboard. A simple lookup can remain one card;
specialist actions appear when the request involves filtering, comparison,
calculation, planning, progress, or configuration.

### Reusable components

| Component | Purpose |
|---|---|
| `AtlasCardShell` | Styling only: material, spacing, pressed/selected/focus state, provenance slot, and adaptive sizing. It owns no routing or action execution. |
| `ResultCardContent` | Noninteractive title, subtitle, icon/placeholder, one to three facts, and source presentation. A sibling primary link/button and separate quick-action buttons avoid nested controls. |
| `ActionCard` | Verb-first next step, short outcome, enable/consent state, and one validated typed action. |
| `SourceBadge` | Packed, Live Atlas, or Community/Web plus release/time detail when expanded. |
| `FactGrid` | Typed label/value facts with “not recorded” and a vertical `LabeledContent` fallback at large text sizes. |
| `CardDeck` | Width-driven one/two/three-column layout that always uses one column at accessibility Dynamic Type sizes. |
| `LoadableStateView` | Consistent idle, loading, empty, error, and content presentation. |
| `ActionBar` | Save, compare, add-to-plan, share/export, and feature-specific actions. |
| `DetailSection` | Closed presentation enum for hero, facts, prose, relationships, steps, actions, and provenance supplied by a typed domain adapter. |
| Collection composition | Shared search field, filter controls, sort, pagination, state, selection, and deck primitives used first by concrete domain screens. |

Build concrete recipe detail/planner and fish collection/detail/compare views
first. Extract a reusable filtered collection only after those domains prove a
shared query, filter, and paging contract. Detail composition consumes a closed
`DetailSection` enum plus domain adapters; it never interprets arbitrary JSON,
uses `AnyView`, or becomes a god workspace view model. The existing raw-payload
disclosure remains an internal/debug fallback.

### Specialist workspace patterns

| Workspace | Best for | Required behavior |
|---|---|---|
| Detail | One entity, recipe, part, fish, reward, or story entry | Typed facts, relationships, source, actions, and explicit missing values. |
| Filtered collection | Fish, parts, rewards, blueprints, fossils | Facets, sort, paging, saved query, and pre-filtered deep links from Atlas. |
| Compare | Items, recipes, bait, or parts | Two to four compatible records, a typed comparison schema, differences, and “not recorded” distinct from unequal. At large text sizes use a vertical record/difference mode instead of horizontal scrolling. |
| Planner/checklist | Recipe graph and building material totals | Deterministic calculation, alternatives, cycles, quantities, local progress, and pack-staleness handling. |
| Guide/timeline | Ordered, sourced definitions | Definition separate from local progress; preserve only supported ordering/dependencies, and keep supplemental current status separately sourced. |
| Catalog/configurator | Ship/corvette parts and later validated builders | Typed sections, selections, summary, and only rules supported by the data. |
| Reader | Story categories/pages/entries | Ordered navigation, safe source-markup rendering, search, reading progress, and bookmarks. |

## On-Device Tool Strategy

Screens and tools are related but not one-to-one. Tools should represent a
bounded player question, while screens present and manipulate the result.

Keep `LocalDatabaseToolRegistry` concrete, fixed, SQLite-only, and read-only.
Replace JSON-string results with bounded typed outputs carrying a status,
evidence IDs, pack release, and source SHA. `LocalKnowledgeToolRegistry`
composes those database tools with explicitly approved pure calculation tools;
it cannot depend on network clients, saved repositories, routers, or action
executors.

### Core tool bundle

- `search_entities`
- `get_entity`
- `search_recipes`
- `get_recipe`
- `recipes_for`
- `recipes_using`
- `search_content`
- `get_content`
- `get_pack_provenance`

### Domain bundles

| Domain | Semantic tools | Native destinations |
|---|---|---|
| Recipe planning | `plan_recipe`, `compare_recipe_paths` | Recipe detail, route chooser, scaled plan, checklist. |
| Fish/bait | `find_fish`, `compare_bait_for_conditions` | Filtered fish guide, fish detail, bait comparison. |
| Expeditions | `list_expeditions`, `get_expedition_rewards` | Historical archive, season/reward-group detail, reward detail. |
| Building | `find_building_parts`, `calculate_build_cost`, `parts_using_material` | Part collection/detail, blueprint-only browse, material plan. |
| Ship parts | `find_ship_parts`, `compare_ship_parts` | Class/role catalog, detail, comparison, saved configuration. |
| Corvette parts | `find_corvette_parts`, `summarize_corvette_materials` | Category catalog, recorded-requirement detail, saved configuration. |
| Rewards/purchases | `find_rewards`, `find_special_purchases` | Source collection, product detail, saved checklist. |
| Stories | `search_stories`, `get_story_page` | Bookshelf, page reader, reading progress. |
| Fossils/legacy | `find_fossils`, `get_legacy_conversion` | Collection/detail and conversion reference. |

Do not expose every domain bundle on every turn. A deterministic domain router
narrows the safe capability set using user text, current feature focus, and the
pack manifest, then selects the core tools plus at most two to four relevant
domain tools. It does not treat model output or tool content as authoritative
semantic intent. Ambiguous bundle selection produces clarification instead of
silently excluding capabilities. The model cannot change source policy, bounds,
or network permission. Database and web text are untrusted data, never
instructions.

Each query and calculation has app-owned limits for input length, result count,
quantity, recursion depth, alternative count, node count, elapsed time, and
cancellation. Model arguments are normalized and rejected before execution.
Every domain registration also requires a deterministic intent adapter,
repository/calculator path, action resolver, and canonical parity tests so
model-ineligible users receive the same specialist capability.

Provisional bounds to lock and profile in Phase 0:

- normalized query: at most 256 Unicode scalars;
- model-selected tools: at most four domain tools and eight total tool calls in
  one turn;
- search result: at most 25 records per call; detail payload supplied to the
  model: at most 16 KiB after typed projection;
- calculated quantity: integer 1...999,999 with overflow-checked arithmetic;
- recipe expansion: depth 12, five alternatives per node, 500 visited nodes,
  and a 750 ms calculation budget;
- cooperative cancellation between SQL steps and graph expansions.

Changing a bound requires fixture, performance, and denial-of-service test
evidence; a model argument can never raise it.

Mutating actions are not model tools. Generated save/remove/progress requests
become short-lived `PendingAction` values binding the resolved action, exact
IDs/effect, originating turn, evidence IDs/digest, active pack release,
issued/expiry times, confirmation requirement, single-use nonce, and consumed
state. The executor revalidates immediately, consumes atomically, and rejects
decline, expiry, cancellation, double tap, replay after relaunch, or pack
mismatch. Direct toolbar actions initiated by a tap may remain immediate.

Export opens a user-initiated share sheet showing the exact payload and never
silently includes conversation text or private notes. Import is a separate
untrusted-write capability, not the inverse of export; it remains deferred until
it has schema/size/depth validation, unknown-field policy, preview,
confirmation, atomic persistence, collision handling, and rollback.

## Saved Artifacts and Persistence

Replace direct `UserDefaults` artifact storage before the first planner ships.
A single-writer actor-backed repository owns atomic files in Application
Support. Its explicit envelope contains `storeSchemaVersion`, artifact kind,
per-kind payload version, timestamps, stable artifact ID, originating pack
release/capabilities, and a checksum. Corrupt or truncated files are quarantined
without destroying the last valid copy.

The bookmark migration is idempotent. It leaves the old key untouched until the
new store has been written, reopened, and verified; repeating the migration must
not duplicate artifacts. Avoid synthesized Codable for one growing
associated-value enum—each kind has an explicit versioned payload codec.

A saved recipe plan persists immutable inputs, selected alternatives, computed
output/checklist, progress, engine version/bounds, and originating pack. A pack
change never silently rewrites it. Recompute creates a preview/new revision with
a diff; the old revision remains until confirmation. Checked progress transfers
only across exact stable line-item identities, while missing recipes and changed
quantities are surfaced for review.

The same stale/revision rules apply to configurations, guide progress, and
saved comparisons. Export needs a documented collision-free external schema;
import collision policy must be approved before import is implemented.

## Typed Data Promotion Plan

The 4,752 `nms_content_records` are sufficient for lossless compatibility, but
specialized filtering and calculation need normalized query fields. Promotion
is additive: keep the original dataset ID, source identity, payload JSON, and
unknown attributes beside typed projections.

Every feature family follows the same gate:

1. Define the user questions, screen facts, filters, sorts, and relationships.
2. Add fixture and production contract tests that decode 100% of records while
   preserving unknown values.
3. Normalize query-critical fields during SQLite pack generation, including
   child tables for arrays and ordered nested records.
4. Add indexes/FTS and validate counts, ordinals, conversions, and referential
   coverage.
5. Add typed Swift DTOs, repository queries, presenters, and bounded tools.
6. Gate the feature by pack schema/capability, not merely by app version.

Source enums must use known cases plus an unknown/raw fallback. Empty strings,
string-encoded numbers/booleans, authoritative key spellings, array order, and
source markup require explicit conversion rules. A projection must never drop a
field merely because the first screen does not display it.

Adding normalized feature tables should create a new pack schema version. The
app must understand the old compatibility payload until the new Background
Asset is installed, then enable specialist screens from the manifest capability
set. The current immutable release/rollback mechanism remains unchanged.

### Proposed projection groups

| Group | Proposed normalized surface | Current data and constraints |
|---|---|---|
| Fish/bait | Fish, fish-biome membership, bait effects, canonical entity references, feature FTS | 226 fish and 621 bait. All join canonical entities. Bait is condition-based, not species-specific; nullable size and 170 empty fish descriptions are valid. The source does not define a formula for combining bonuses. |
| Expeditions | Seasons and explicitly sorted reward groups with ordered nested rewards | 21 seasons and 252 unique rewards. No dates, availability, objectives, dependencies, or usable `FinalReward`; packed presentation is historical rather than a full phase guide. |
| Building | Parts, ordered requirements, purchasable-blueprint membership, feature FTS | 1,654 parts, 1,571 requirement rows, 217 matching blueprint IDs. Parts are not canonical products; all requirement materials resolve to canonical entities. There are 85 empty names and 597 empty requirement arrays; hide 295 `NotEnabled` rows by default. |
| Ship | Parts plus reviewed nullable ship-class, part-kind, and component-role mappings | 284 parts. Four `Reactor` rows are a part kind rather than a ship class. There is no canonical entity relationship, material requirements, geometry, or compatibility graph; `Category` is not useful. |
| Corvette | Parts, many-to-many category facets, derived `NotEnabled` marker, and requirements | 633 parts, including 42 empty names. Only 47 have requirements; 586 have empty requirement arrays. The disabled marker is true only when `WikiCategory == NotEnabled`; unknown values are not silently classified. There is no socket/geometry/orientation/compatibility graph. Composite categories require a tested split policy. |
| Rewards/purchases | Reward items, many-to-many reward sources, special purchases | 594 rewards and 332 purchases. Most join products. Ten unnamed construction rewards link to both building and corvette feature records with different payloads, so retain both relationships. Currency/shop meanings need validation before user-facing labels. |
| Stories | Ordered categories, pages, entries, reader FTS | 7 categories, 40 pages, 592 entries. Preserve order and empty pages; source markup needs a safe renderer. |
| Fossils | Fossil records and category facets | 143 records. No canonical product or creature/set relationship; useful as a collection checklist, not an assembly system. |
| Legacy | Conversion rules, non-converting legacy records, and flags | 20 records: eight convert to `BAIT_BASIC` at ratio 10 and twelve have no conversion values. Treat the latter as legacy/tombstone references, not conversion rules. |

## Prioritized Specialist Experiences

### P0 — Recipe Planner

**Why first:** The canonical graph already contains 2,181 recipes and 4,003
ordered ingredients, and planning turns lookup into a high-value player action.

**Screens:** target/quantity setup, alternative route chooser, expandable
dependency tree, totals, cycle/error explanation, and a saved checklist.

**Engine:** pure deterministic graph traversal with quantity scaling, alternate
paths, depth bounds, cycle detection, and stable plan IDs. The model interprets
the goal and explains options; it never calculates ingredient truth.

**Done when:** known multi-step fixtures produce exact totals; alternate paths
are explicit; cycles and missing edges never hang; a plan saves, restores,
marks progress, records its pack release, and can preview a user-confirmed new
revision after an update without overwriting the original.

### P0 — Fish and Bait Guide

**Why next:** This is the strongest typed feature family and has complete
canonical relationships.

**Screens:** faceted fish collection, fish detail with recipe uses,
condition-aware bait comparison, and two-to-four item comparison. Filters include
biome, quality, size, time, storm, and mission restrictions.

**Rules:** Present source quality codes through an explicit display map, retain
raw values, support multi-biome fish, and show missing descriptions/size as “not
recorded.” Filter bait by General/Day/Night/Storm and display rarity/size bonuses
separately. Do not compute a single rank until the source semantics or an
explicitly labeled app heuristic is reviewed and tested.

**Done when:** all 226 fish and 621 bait records project; facet counts match the
pack; every canonical link resolves; bonus comparison is deterministic and
transparent; no text implies unsupported species-specific affinity.

### P1 — Expedition Archive and Reward Guide

**Screens:** historical season list, season detail, explicitly sorted reward
groups, ordered rewards within each group, reward detail, and local owned/saved
tracking.

**Rules:** Label packed data Historical. Current availability can appear only
as separately fetched, time-stamped Live/Web evidence after consent. Do not
infer meaning for the `-1` reward group or empty final-reward field without an
upstream contract. Sort the outer group tokens deliberately and preserve each
reward array's ordinal; do not infer chronology from JSON object ordering.

**Done when:** all 21 seasons and 252 unique rewards flatten with stable order;
reward cross-links resolve; historical and current provenance cannot be
confused; progress remains local.

### P1 — Building Catalog and Material Planner

**Screens:** filtered part collection, blueprint-available view, detail with
requirements, reverse “builds using this material,” quantity calculator, and
saved material checklist.

**Rules:** Hide `NotEnabled` by default with an explicit advanced toggle. Treat
an empty requirements array as “no recorded requirements,” never zero cost,
until upstream semantics prove otherwise. Do not claim blueprint price, vendor,
or ownership data that is not present. Retain the source spelling
`purchaseable_building_blueprints` as a compatibility alias while using correct
product copy.

**Done when:** all parts and requirement rows project, all material links
resolve, blueprint membership matches 217 records, and totals are deterministic
for selected parts with recorded requirements while unknown costs remain
explicit.

### P1 — Ship Parts Catalog and Configuration Notebook

**Why here:** Ship parts are an explicitly desired player-facing family, so the
catalog is prioritized by product demand rather than schema depth. Rewards and
stories are more structurally complete, but do not replace this job.

**Screens:** ship-class/role catalog, part detail, comparison, and a saved
configuration notebook that records selected parts and notes without claiming
valid assembly.

**Rules:** Model Hauler/Fighter/Explorer/Solar as ship classes and the four
`Reactor` records as a separate part kind. Validate a component-role mapping
from stable source description IDs before exposing the role facet. Clearly
label configuration as a planning notebook. Use app glyphs/placeholders until
the asset gate passes.

**Done when:** all 284 records project; every unknown role remains visible as
Unknown rather than being guessed; comparison distinguishes missing values;
saved configurations survive relaunch, retain their originating release, and
become stale/revalidatable across pack changes; no compatibility claim appears.

### P2 — Corvette Parts Catalog

**Screens:** enabled category collection, part detail, requirement totals for
the supported subset, comparison, and saved configuration notebook.

**Rules:** Normalize composite categories with an explicit tested policy. Set a
disabled marker only when `WikiCategory == NotEnabled`, and hide those 18
records by default. An empty requirements array means “not recorded,” not zero cost.
Defer the visual builder and validation until a proven connection graph exists.

**Done when:** all 633 parts project, category membership is lossless, all 110
requirement rows resolve, and the UI never treats missing compatibility as
approval.

### P2 — Rewards and Special Purchases

**Screens:** collection by Twitch/Expedition source, reward detail, expedition
cross-links, purchasable-product browse, subtype/mission-tier filters, and saved
checklists.

**Rules:** Reward source is many-to-many. Do not label base value as a particular
currency or expose raw shop numbers as meaningful names until verified. Keep
both building and corvette links for the ten construction rewards; do not choose
one silently, and use the expedition reward name when a sourced display fallback
is required.

### P3 — Stories, Fossils, and Legacy Reference

- **Stories:** bookshelf, full-text search, ordered reader, reading progress,
  bookmarks, and safe source-markup rendering. Public release remains subject
  to the text licensing decision.
- **Fossils:** collectible grid, part-category filters, and display-case
  checklist. Do not invent creature/set compatibility.
- **Legacy:** compact conversion/migration reference for the eight actual rules,
  plus clearly separate tombstone/reference rows for the twelve records without
  conversion values. This can remain a typed detail/list rather than a full
  workspace.

## Delivery Plan

Effort below is engineering effort for one focused implementation stream and
excludes App Store signing, physical-device release rehearsal, and the external
publication/licensing decision. It is a sizing aid, not a release-date promise.
Data projection and UI work can run in parallel after contracts are locked.
Cancellation, pack invalidation, accessibility, deterministic parity, and
malicious-model-double tests are acceptance criteria in every slice rather than
work deferred to final hardening.

### Phase 0 — Lock contracts and prototypes (about 1 week)

- Approve the contracts, non-goals, and first beta scope: recipe planning plus
  fish/bait.
- Add representative prompt, data, route, and screen fixtures for those two
  workflows only.
- Prototype answer/action cards, the recipe planner, and concrete fish
  collection/detail/compare layouts at compact, regular, and accessibility
  widths.
- Lock the authority matrix:

| Owner | Authority |
|---|---|
| Model | Semantic selection and proposals only. |
| Source policy | Allowed sources, exact consent, and capability bundle. |
| Repository/source | Raw facts and typed not-found/failure. |
| Pure engines | Bounded deterministic calculations. |
| Evidence ledger | Evidence identity, ancestry, release, and freshness. |
| Grounded renderer | Factual wording from closed claim/fact references. |
| Resolver/router | Valid destinations from resolved actions. |
| Action policy + confirmed executor | Allow/deny/confirm decisions and app-owned writes. |

**Exit:** Both beta workflows have a user job, input, output, route, facts,
calculation ownership, tool/action contract, empty/error/stale state, and
explicit unsupported claims.

### Phase 1A — Shell, state, and persistence foundation (about 2 weeks)

- Add an injected `AppEnvironment`/composition root with fixture repositories,
  saved-store URL, clock/ID sources, network spy, and fake model availability
  and planning.
- Centralize scene-local routes and destination factories; project the same
  state into compact stacks and regular-width split navigation.
- Define repository APIs as `async throws` domain values with typed
  not-found/unsupported failures. Each `@MainActor @Observable` feature model
  owns its own `LoadState<Value>`; repositories do not return presentation
  state.
- Introduce the actor-backed, atomic, versioned saved-artifact store and verified
  bookmark migration.
- Add source/pack presentation, cancellation, generation/task IDs, and pack
  invalidation hooks to shared state.
- Retrofit one thin existing flow—Atlas entity result -> entity detail -> recipe
  detail -> save/relaunch—through the new router, repository, and card
  primitives.

**Exit:** Cross-section routing retains both back stacks through compact/regular
transitions; every displayed result has pack/source identity; not-found and
failure remain distinct; corrupted/truncated saved storage recovers safely; the
existing entity/recipe flow works offline and passes baseline accessibility.

### Phase 1B — Evidence, model, action, and tool foundation (2–3 weeks)

- Implement source/action policy, `EvidenceLedger`, `DerivedEvidence`, closed
  claim/fact references, `ProposedTurnPlan`, grounded renderer, fallback
  dispatch, action resolver, and complete `PendingAction` execution.
- Complete typed bounded recipe/content/provenance database tools and the
  network-free knowledge-tool composition layer.
- Extract the conversation engine actor from `AtlasSessionController`; key the
  live model session by pack/capability bundle and retain bounded app-owned
  context.
- Add one-shot external consent receipts, safe outbound-query derivation, typed
  clarification/follow-up chips, cancellation, stale-turn suppression, and
  pack-change session recreation.
- Add generative-routing feature flags and malicious model doubles for wrong
  claim kinds, stale/well-formed evidence, unknown actions, oversized inputs,
  injected outbound queries, replayed confirmations, and cancellation during
  resolution.

**Exit:** No raw model fact, route, URL, or write reaches the UI/executor; every
invalid/unavailable model outcome uses the deterministic path; database failure
fails closed; local prompts/misses/errors cause zero network requests; action
confirmation is exact, expiring, single-use, and pack-bound.

### Phase 2 — Recipe planner vertical slice (4–6 weeks)

- Build and exhaustively test the bounded pure graph engine and derived-evidence
  adapter.
- Add concrete plan, alternative-route, and checklist presentation models and
  adaptive/accessibility screens.
- Add immutable saved-plan revisions, progress, pack-stale comparison, and
  user-confirmed recompute preview.
- Add bounded knowledge tools, generated proposal resolution, deterministic
  prompt/action mappings, and parity tests.

**Exit:** prompt -> grounded answer -> Open Plan -> choose route -> save and
check off -> relaunch works offline at compact and regular widths. Exact totals,
alternatives, cycles, bounds, cancellation, pack swaps, model-unavailable
behavior, and stale plan revisions pass.

### Phase 3A — Typed feature pack v2 foundation (2–3 weeks)

- Add normalized feature projection support, capability manifest flags,
  v1 compatibility fallback, indexes, release/rollback handling, and production
  contract tests.
- Project fish, biomes, and bait with 100% decode, raw-payload preservation,
  canonical-link, facet-count, and unknown-enum tests.
- Add async repositories, bounded query tools, deterministic intent/action
  adapters, and performance signposts.

**Exit:** 100% record projection, correct facet counts/joins, transparent bait
bonus fields, production-pack performance within budget, capability gating, and
safe v2 -> v1 rollback while a route/query is active.

### Phase 3B — Fish/bait experience (3–4 weeks)

- Build concrete collection, filter, detail, recipe-relationship, condition
  comparison, saved-query, and deep-link experiences.
- Extract shared collection/compare composition only where recipe and fish
  implementations prove the contract.
- Add generated and deterministic handoffs, derived-evidence/source copy, empty
  description/bonus behavior, and the full adaptive/accessibility matrix.

**Exit:** The P0 definition of done passes, including all 226/621 records,
condition-only bait claims, rapid-filter cancellation, pack swap during load,
and generative/deterministic record-action parity.

### Phase 4A — Expedition archive (3–4 weeks)

- Normalize explicitly sorted reward groups and ordered rewards.
- Add the historical season/archive experience, saved progress, reward links,
  deterministic/model handoffs, and separately sourced optional current status.

**Exit:** The expedition P1 definition of done passes; no objective, date,
availability, phase chronology, or `-1` meaning is inferred.

### Phase 4B — Building catalog and material planner (4–5 weeks)

- Normalize parts, blueprint membership, and requirements; add catalog, reverse
  material lookup, recorded-cost calculations, checklist, and saved revisions.
- Add the deterministic adapter, knowledge tools, action resolver, and complete
  empty-name/empty-requirement behavior.

**Exit:** The building P1 definition of done passes; unknown requirements never
become zero cost and acquisition claims remain bounded to packed facts.

### Phase 4C — Ship catalog and configuration notebook (3–5 weeks)

- Complete the component-role research/approval gate and separate Reactor part
  kind from nullable ship class.
- Normalize the catalog, then add detail, comparison, saved configuration
  notebook, deterministic/model handoffs, and no-compatibility messaging.

**Exit:** The ship P1 definition of done passes; unknown roles remain unknown,
and malicious/generated text cannot imply valid assembly.

### Phase 5A — Corvette catalog (3–5 weeks)

- Normalize many-to-many categories, the derived disabled marker, and recorded
  requirements; add catalog, detail, comparison, and configuration notebook.
- Add the deterministic adapter, bounded tools, action resolver, and explicit
  no-requirements/no-compatibility states.

**Exit:** The corvette P2 definition of done passes independently of rewards.

### Phase 5B — Rewards and purchases (3–4 weeks)

- Normalize many-to-many sources, canonical product links, dual
  building/corvette construction links, and purchase facets.
- Add collection/detail/cross-link/saved-checklist screens and deterministic and
  generated entry paths.

**Exit:** The rewards P2 definition of done passes; ambiguous links, names,
currency, and shop fields are never silently resolved.

### Phase 5C — Export (1–2 weeks; import remains separate/deferred)

- Define a versioned external schema, privacy review, exact share preview,
  redaction defaults, size bounds, and export tests.

**Exit:** User-initiated export never includes unselected conversation or note
content. Import is not enabled without its own untrusted-write design and gate.

### Phase 6A — Story reader (3–4 weeks)

- Normalize ordered hierarchy/FTS, add safe markup rendering, reader search,
  progress, bookmarks, deep links, and licensing capability gates.

**Exit:** Order, empty title/page behavior, markup, saved progress, restoration,
and public-release gating pass.

### Phase 6B — Fossils and legacy reference (1–2 weeks)

- Add the fossil collection/checklist and the split eight-rule/twelve-tombstone
  legacy reference with deterministic entry paths.

**Exit:** No fossil compatibility or absent legacy conversion is invented.

### Phase 7 — Device evaluation and beta hardening (2–3 weeks, then ongoing)

- Add richer multi-turn clarification/follow-up behavior and streaming polish
  on top of the minimum safe context/cancellation already shipped.
- Run system-model evaluations on pinned physical OS/device combinations and
  the full model-ineligible airplane-mode matrix.
- Aggregate accessibility, performance, offline, diagnostics, production-pack
  parity, rollback, and adversarial regression evidence from every slice.
- Increase generative-routing rollout only when deterministic/generative record
  and action parity remains inside the defined gates.

**Exit:** the beta quality gates below pass on model-eligible and ineligible
devices, with airplane mode and the production pack.

## Quality Gates

### Data and repository

- 100% of records in a promoted family decode or fail the pack build.
- Unknown enum values and attributes survive round-trip projection.
- Nested ordinals, count floors, canonical relationships, and source identity
  are validated for every pinned import.
- Query fields have intentional indexes/FTS; views do not parse arbitrary JSON
  to filter or sort.
- No `try?` path may convert a database failure into “no results.”

### Tools, evidence, and model

- Every tool has typed bounds, direct success/no-match/not-found/error tests,
  evidence IDs, release ID, source SHA, and a production-pack test.
- A network spy observes zero requests for local prompts, misses, database
  errors, model tool requests, and prompt-injection content.
- Validators reject unknown/stale evidence, altered quantities, invented
  ingredients or relationships, arbitrary URLs/routes, and unsupported writes.
- Canonical prompts produce the same record and action IDs through generative
  and deterministic paths. Golden tests assert IDs and facts, not exact prose.
- Injected tests cover every currently known Foundation Models availability and
  error case plus an unknown catch-all; each yields a useful deterministic
  result.
- Each tool/action slice adds malicious-model-double tests for mismatched claim
  kinds, stale but well-formed evidence, unknown actions, oversized arguments,
  injected outbound queries, confirmation replay, and cancellation during
  resolution.
- Release targets: 100% factual-block evidence coverage, zero invalid action
  resolutions, zero unauthorized network calls, and zero unconfirmed writes.

### UI, persistence, and accessibility

- Unit tests cover cross-section routing/back-stack retention, route
  restoration, compact/regular transitions, action resolution, stale/deleted
  destinations, filter cancellation, comparison alignment, planner
  cycles/alternatives, corrupted/truncated storage, migration idempotency,
  confirmation expiry/replay, pack swap during load, and v2 -> v1 rollback.
- Deterministic UI tests use injected fixture repositories, isolated saved-store
  URLs, clock/ID sources, network spies, and fake model planners/availability.
  They cover Atlas -> action -> workspace -> save -> relaunch at compact and
  regular widths, including model-unavailable and airplane-mode paths. Real
  Foundation Models evaluation remains a separate physical-device matrix.
- No fixed card heights; layouts reflow at accessibility Dynamic Type sizes.
  Touch targets are at least 44 x 44 points.
- Source, selection, progress, and differences use text/icon semantics rather
  than color alone. VoiceOver reads compare rows and ordered guide steps
  meaningfully.
- Announce generation completion/error, not every token. Expose Stop and Retry,
  manage focus to the completed answer, and respect Reduce Motion.
- Provide Reduce Transparency fallbacks for material cards, visible keyboard and
  pointer focus, labeled Clear Filters and selection counts, separately
  focusable card actions, and non-horizontal Compare/Planner layouts at large
  text sizes.
- Test dark mode, at least WCAG 2.1 AA text/control contrast, VoiceOver, Switch
  Control, Voice Control, Full Keyboard Access, Stage Manager widths, and
  orientation changes without recreating state. Manual Accessibility Inspector
  and spoken-order passes remain required because UI automation cannot validate
  them completely.

### Provisional performance budgets

Before these become release gates, record the reference device/OS, exact
production pack release, cold versus warm cache, fixed query corpus, run count,
percentile method, planner depth/node limits, and signpost start/end points.
Store the measurement profile with the result.

- Local search p95: under 200 ms on the production pack.
- Cold first collection/detail load p95: under 500 ms after pack readiness on
  the reference oldest-supported device.
- Warm cached collection/detail presentation p95: under 300 ms.
- Bounded recipe plan calculation p95: under 500 ms.
- Deterministic answer p95: under 500 ms after pack readiness.
- On-device model-planned completed answer p95: under 8 seconds on the oldest
  eligible device, with cancellation available.
- Zero remote inference in every configuration.

## Suggested Module Boundaries

The exact folder names can follow the existing Xcode project, but dependencies
should point in this direction:

```text
App shell / Router / Composition root
              |
              +--> Conversation presentation
              |       |
              |       +--> AtlasConversationEngine
              |                |
              |                +--> Policy / Model planner / Validator
              |                +--> Local evidence repositories and tools
              |
              +--> Feature presentation
              |       +--> Collection / Detail / Compare / Planner / Guide
              |       `--> Domain presenters and view models
              |
              +--> SavedArtifactsRepository
              |
              `--> Pack coordinator / SQLite repositories
```

- SwiftUI views receive feature view models and immutable, `Sendable`
  presentation models.
- Domain and repository services do not import SwiftUI.
- App-wide state is limited to pack/release, settings, and shared services; the
  router and selection are scene-local.
- Conversation and each specialist workspace own separate observable state.
- Async repository APIs perform SQLite work off the main actor and return
  domain values or typed errors. Each `@MainActor` feature model maps those into
  its own `LoadState<Value>`.
- Optional network clients remain outside model-planning and knowledge-tool
  dependencies.

## Immediate Backlog

The next implementable thin slice does not depend on App Store Connect:

1. Lock the Phase 0 authority matrix and recipe/fish contracts.
2. Add the injected environment, scene router, provenance, repository error,
   `LoadState`, and saved-store foundations.
3. Retrofit the existing entity -> recipe -> save/relaunch flow end to end and
   test it at compact/regular/accessibility widths.
4. Add evidence/derived-evidence, closed claims, grounded rendering, action
   resolution/policy, fallback, confirmation, and the missing core local tools.
5. Extract the pack/capability-keyed conversation engine while preserving the
   current deterministic behavior.
6. Implement the bounded recipe graph engine, then complete prompt -> validated
   plan action -> adaptive planner -> saved revision -> relaunch.
7. Only after that slice passes, start pack-v2 fish/bait projections and build
   concrete fish screens. Extract compare/collection abstractions from proven
   implementations instead of placeholder shells.

This produces one complete high-value generative-to-native workflow before
multiplying specialist screens or prematurely freezing generic UI abstractions.

## North Star

Atlas should feel like a trusted on-device co-pilot, not a chatbot pasted over
a database and not a collection of disconnected utility screens. A player asks
for an outcome, Atlas explains what the installed evidence supports, and one
tap opens the exact native tool needed to compare, calculate, plan, configure,
read, or track it. The experience remains fast and useful without Apple
Intelligence, transparent about provenance and uncertainty, and honest about
what the local data cannot establish.
