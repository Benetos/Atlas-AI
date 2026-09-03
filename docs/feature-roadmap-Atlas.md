# Feature Roadmap — Atlas

**Date:** 2026-09-01
**App category:** Offline-first game reference utility / companion
**Release posture:** Internal pre-beta until the publication and licensing gate is resolved

## Current State

Atlas has two unusually strong foundations for an early product:

- A pinned, reproducible No Man's Sky data pipeline with an active read-only
  Supabase revision.
- An Apple companion app that can read a versioned SQLite snapshot, browse
  entities and recipes, save records locally, and optionally consult live or
  community sources.

The active dataset contains 2,597 canonical entities, 2,181 recipes, 4,003
ordered ingredient relationships, and 4,752 feature records. The repository
also preserves 88,009 lossless source records outside the client pack.

The app is now a truthfully buildable internal alpha: a prepared Debug checkout
embeds the complete generated production database, while Release excludes the
bundled pair and embeds a real Apple-hosted Background Assets downloader
extension. The tiny disposable database is isolated to mutation/corruption
tests. The full pinned production import is validated and packageable as an asset archive.
Runtime code downloads both database and sidecar, copies them out of Apple's
process-scoped location, verifies them, atomically activates an immutable
release, and recovers one prior verified release if the active copy is corrupt.
The advertised offline questions now pass through a typed
query planner instead of sending whole conversational sentences to strict FTS.
Library search includes items, recipes, and feature records, browse results are
paginated across all 18 item, recipe, and compatibility categories, and feature
cards open a compatibility detail screen. Normal Debug builds and hosted
integration tests use the full generated production snapshot; the three-row
preview is isolated to mutation and corruption tests.

It is not release-ready. Apple-hosted upload, signing/app-group registration,
and a first-install/upgrade/rollback rehearsal on physical signed devices still
need App Store Connect. Pack bytes are not yet reproducible or cryptographically
bound to a resolved Git tree and transformer identity. The on-device
system-model narration is single-turn, non-streaming, and not yet behind an
injectable provider boundary, although it is optional and bounded by an
eight-second fallback to the deterministic SQLite answer; live results lack
card-level provenance; hosted
CI and release automation are incomplete; and public distribution is blocked
by an unresolved rights/publication decision.

## Summary

Atlas should win on one promise: a player gets a trustworthy, actionable NMS
answer in under ten seconds, offline, without an account. The data model is
already capable of supporting that promise. The priority is therefore not more
datasets or a broader platform footprint; it is closing the reliability gap
between the data foundation and the player-facing core loop.

The non-negotiable execution invariant is: **all language-model inference and
every canonical database capability run on the device**. The production model
tool registry accepts only the installed read-only SQLite store. Atlas never
sends prompts, local evidence, conversation history, or model output to a cloud
model. Supabase/Postgres and web clients are excluded from the model-planning
and local knowledge-tool dependency graph. Optional network retrieval is controller-owned,
explicitly requested, source-tagged, and never a fallback for a local miss or
database failure.

The critical path is:

```text
truthfully runnable app
  -> correct offline retrieval
  -> full production database installed on-device
  -> verified pack lifecycle and rollback
  -> fixed local database-tool boundary
  -> explicit on-device model-planning boundary
  -> evidence-validated conversational presentation
  -> internal beta quality
  -> public-release decision
```

Images, Android, accounts, and broad social features stay outside that path.

After the grounded conversation boundary is in place, Atlas will use a
generative-to-native interaction model: the on-device model interprets the
player's goal and proposes evidence-bound actions, while the app opens typed
planners, comparisons, guides, catalogs, readers, and saved artifacts. The
detailed architecture, data-backed feature order, screen contracts, tools,
effort ranges, and quality gates are defined in
[SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md).

## On-device Database Decision

The production app is a local database product. Its complete canonical read
surface—Atlas pre-retrieval, model-callable tools, Library search/browse,
details, recipes, content payloads, and pack provenance—runs as SQL against an
installed immutable SQLite snapshot. Supabase remains a build/publishing source
and an optional explicitly requested comparison, not a runtime dependency for
answers.

The current model registry contains five proven-local tools:
`search_entities`, `get_entity`, `recipes_for`, `recipes_using`, and
`search_content`. `LocalDatabaseToolRegistry` has a concrete
`SQLiteNMSStore` initializer and no settings, URL, credential, or network-client
dependency. The deterministic planner uses the same store. Ordinary prompts,
empty results, and SQLite errors do not activate Live Atlas or web search.

Before beta, expand and test the approved tool surface where the model needs
more than the current tools expose:

| Capability | Local pack requirement | Tool status |
|---|---|---|
| Entity search/detail | `nms_entities` + entity FTS | Implemented |
| Recipe search/detail | `nms_recipes` + ordered ingredients | Deterministic path implemented; model search/detail tools pending |
| Producing/using graph | recipes + ingredients joins | Implemented |
| Feature search/detail | `nms_content_records` + content FTS + payload | Search implemented; full payload tool pending |
| Preferred localization | `nms_localizations` | Packed; dedicated lookup pending if product needs it |
| Pack identity/provenance | `pack_manifest` + row source SHA | App reads manifest; tool/result provenance pending |

Private ingestion tables, service-role operations, source-record staging, and
import activation deliberately stay off the device because they are publishing
operations, not player database capabilities.

Required structural safeguards:

- Keep local tools in one fixed registry that accepts `SQLiteNMSStore` only.
- Keep optional network clients in a separate controller-owned dependency
  graph; they never conform to or register as model tools.
- Open SQLite read-only, fail closed on pack errors, and add defensive
  query-only/write/attach tests.
- Bind every result to the active pack release ID and source provenance.
- Reject Release builds containing the preview fixture or lacking the verified
  full pack installation path.
- Exercise every registered database tool under a network-deny test harness.

## AI Implementation Decision

The v1 generative provider is Apple’s on-device
`SystemLanguageModel.default`. It is selected explicitly when constructing the
Foundation Models session so future framework providers cannot change the
privacy boundary by accident. Atlas does not request the Private Cloud Compute
entitlement and has no third-party model endpoint.

| Provider | v1 status | Network | Product role |
|---|---|---|---|
| Apple `SystemLanguageModel.default` | Primary on eligible, ready devices | None | Interpret the goal, use approved local read tools, and propose an evidence-bound turn/action plan |
| Deterministic planner + templates | Required on every device | None | Full search, grounded summaries, and cards when no model is available |
| Bundled Core AI/Core ML model | Deferred evaluation | None | Possible generative coverage for unsupported hardware |
| Apple Private Cloud Compute or third-party model API | Prohibited | Required | No fallback role |

Target component boundaries:

1. `SourcePolicyDecision` deterministically enforces local/live/web source
   intent, exact consent, and a safe capability bundle before generation.
2. `AtlasModelPlanning` explicitly wraps `SystemLanguageModel.default`, chooses
   only approved local read tools, and returns a structured
   `ProposedTurnPlan`.
3. The current `AtlasQueryPlan` remains the complete deterministic fallback and
   supplies source-policy signals until the dedicated envelope replaces that
   part of it.
4. Repositories and tools produce typed records in a source-tagged
   `EvidenceLedger` with stable evidence and pack-release IDs.
5. `ClaimValidator` and `ActionResolver` resolve proposals against the ledger;
   native renderers produce factual blocks and `ActionPolicyDecision` handles
   the exact resolved action.
6. `DeterministicPlanner` returns the same record/action surface without a
   model.
7. A future bundled provider may implement `AtlasModelPlanning` only after a
   device-coverage and performance gate.

The system-model availability state must distinguish an ineligible device,
Apple Intelligence disabled, model not ready, and unsupported language/locale.
The user-facing behavior is identical in each case—grounded local results still
work—but the explanation and remediation differ.

A bundled model is not part of the default v1 schedule. Before adding one, test
model license and updateability, download/app size, supported devices and
locales, peak memory, time to first token, completion latency, sustained thermal
behavior, answer quality, and tool/guided-generation support. Beta evidence must
show that deterministic cards are insufficient on unsupported hardware.

## Gap Analysis — What's Missing

### Must-Have Gaps

**Publication and licensing decision**
Why users expect it: A distributed app needs a clear right to expose its data,
text, attribution, and any future imagery.
Current state: Unresolved. The documented posture is internal-only while the
hosted reference API is anonymously readable.
Effort: M, with external legal/product input.

---

**End-to-end data-pack lifecycle**
Why users expect it: The app must install, verify, update, and recover its core
offline data without manual file copying.
Current state: Implemented in the repository: full-pack packaging, native
ExtensionKit target, managed download/progress, copied staging, sidecar and
SQLite validation, immutable releases, atomic active/previous state, automatic
rollback, a full production-role Debug snapshot, a test-only disposable
preview, and corruption tests. Remaining work is the
signed App Store Connect upload and physical-device lifecycle rehearsal.
Effort: S–M, primarily distribution validation.

---

**Complete on-device database and tool parity**
Why users expect it: Offline claims are only true if every supported answer and
screen has its complete production data and query capability on the device.
Current state: All five registered model tools are SQLite-only and have direct
full-production-pack integration coverage; remote fallback is explicit-only.
The production archive is validated against the pinned 2,597-entity count
profile and can be installed by the managed runtime. Typed specialist APIs and
physical-device Foundation Models evaluation remain incomplete.
Effort: M.

---

**Automated iOS and pipeline quality gates**
Why users expect it: A reference answer is only useful if app builds, pack
integrity, migrations, and core questions cannot silently regress.
Current state: Thirty-three Python tests, 30 iOS tests, a production archive
validator, full-pack database integration coverage, and Debug/Release
app-bundle verification exist locally. Hosted CI and a complete physical-device
UI/Foundation Models smoke suite are missing.
Effort: M.

---

**Cryptographic source-to-release binding**
Why users expect it: A pinned commit is meaningful only if the transformed
bytes are proven to come from that exact Git tree.
Current state: Input and output hashes are recorded, but a caller can supply a
commit override and an independent working-tree source directory without a
cryptographic comparison between them. Import identity also permits a corrected
transformer to reuse the same repository/commit release identity.
Effort: M.

---

**On-device model runtime and provider boundary**
Why users expect it: “Works offline” and “private” must remain true across OS
updates, unavailable models, and future framework providers.
Current state: The app explicitly selects `SystemLanguageModel.default` and
falls back to deterministic local results. The model call is still embedded in
the session controller, availability is binary in the UI, failures fall back
silently, and generated text is not structurally tied to evidence IDs.
Effort: M.

---

**Grounded answer contract**
Why users expect it: Atlas must never invent a recipe or blur community text
with canonical data.
Current state: Local cards are deterministic and Apple’s on-device system model
receives tool evidence, including ordered ingredients. Narration is still
instruction-bound rather than validated against a structured evidence envelope.
Effort: M.

---

**Visible source and revision provenance**
Why users expect it: Players need to know whether a result came from their
installed pack, the live Atlas database, or the community web.
Current state: Web cards are labeled. Local and live entity cards share the
same presentation and duplicate identity; SHA inequality cannot establish
which revision is newer.
Effort: S–M.

---

**Release UX and accessibility**
Why users expect it: First-run guidance, usable loading/error states, Dynamic
Type, VoiceOver, a real app icon, privacy disclosure, and support are baseline
App Store expectations.
Current state: Pack retry, explicit search errors, and improved empty states
exist. Formal onboarding, accessibility QA, support, privacy policy, and final
brand assets do not.
Effort: M.

### Common Gaps

**Complete Library facets and sort**
Why users expect it: Players browse by item type, rarity, category, recipe kind,
and feature family—not only by a keyword.
Current state: Keyword scopes and paginated canonical browsing exist; advanced
filters and typed feature-family screens do not.
Effort: M.

---

**Bookmark organization, export, and optional sync**
Why users expect it: A useful companion becomes a personal short list during a
play session.
Current state: Local bookmarks, deletion, recents, and clear-recents exist.
Tags, lists, export, and iCloud sync do not.
Effort: S for lists/export; M for sync.

---

**Multi-turn, streaming Atlas conversation**
Why users expect it: A conversational home should understand follow-ups and
show work without blocking on a full response.
Current state: Each message creates a new model session and returns one complete
reply.
Effort: M.

---

**Operational release record**
Why users expect it: Pack, database, and app versions should identify one
coherent release with an auditable rollback path.
Current state: Source commit and hashes are recorded, but pack output includes a
wall-clock build timestamp and import identity does not include transformer
revision/artifact digest.
Effort: M.

---

**Feedback and diagnostics**
Why users expect it: Beta users need a way to report a wrong answer, missing
record, corrupt pack, or model problem.
Current state: No in-app feedback, diagnostic export, or crash-quality plan.
Effort: S–M.

### Nice-to-Have Gaps

**Recursive recipe planner and quantity calculator**
Why it matters: This turns reference lookup into an actionable crafting plan
and is Atlas's clearest differentiator.
Current state: The ordered recipe graph exists; traversal, alternate-path
selection, cycle handling, quantities, and a shopping list do not.
Effort: L.

---

**Generative-to-native specialist workspaces**
Why it matters: Planning, comparison, filtering, progress, and configuration
are more useful in native workspaces than in prose or raw JSON.
Current state: Generic searchable compatibility cards and details only. The
screen/tool/projection contracts now cover recipe planning, fish/bait,
expeditions, building, ship/corvette parts, rewards, stories, fossils, and
legacy conversions in
[SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md).
Effort: M–L per vertical slice after the shared platform.

---

**Shortcuts, widgets, and deep links**
Why it matters: They make repeated lookups fast during play and enable sharing
specific items or recipes.
Current state: Not present.
Effort: M.

---

**Additional locales**
Why it matters: NMS has a global audience and the source already contains a
localization model.
Current state: The initial pack projects preferred English values only.
Effort: L, primarily data/product QA rather than UI plumbing.

## Implemented Foundation in This Build-Out

- Added the missing Xcode Sources and Resources phases and excluded the source
  Info.plist from resource copying. A real build now contains an executable,
  full generated SQLite database, and privacy manifest.
- Fixed source-level SQLite store failures that had been hidden by the empty
  target.
- Added `AtlasQueryPlan`, with typed local/live/web source intent,
  crafting/refining/cooking operation intent, question-glue removal, and broad
  recipe fallback.
- Made the documented offline examples resolve cleanly: “What is Ferrite Dust
  for?”, “Circuit Board recipe”, “Refining Carbon”, and “How do I cook food?”.
- Added direct recipe search, prefix entity/content search, explicit SQLite bind
  and step error handling, pack-schema checking, and content-record lookup.
- Rebuilt Library around debounced scoped search, recipe results, paginated
  browse, visible error/empty/loading states, and navigable feature records.
- Added generic feature-record detail with readable top-level fields and an
  inspectable lossless JSON fallback.
- Added missing-pack retry, typed first-use web consent, bookmark deletion, and
  recent-history clearing.
- Corrected the Background Assets platform manifest and packaging command, and
  added a verifier that rejects an app bundle without its executable, complete
  pinned Debug pack, privacy manifest, exact live-data URL, or a healthy SQLite database.
- Added a hosted iOS unit-test target covering five query-planning contracts,
  full-pack search/category integration, and complete offline Atlas responses;
  the small fixture remains available only for destructive database tests.
- Corrected Xcode URL escaping so the bundled Supabase endpoint is a valid
  `https://` URL rather than the truncated value `https:`.
- Made SQLite pack publication staged and rollback-safe on handled failures,
  with strict contract, source SHA, hash, row-count, quick-check, and
  foreign-key validation.
- Centralized the model-callable database surface in a fixed local registry,
  made Live Atlas require explicit source intent, removed automatic web lookup
  on local misses, and made local database errors fail closed.
- Bounded Apple Foundation Models narration at eight seconds and retained the
  verified SQLite answer whenever generation is unavailable, fails, or stalls.
- Added an embedded Apple-hosted Background Assets downloader extension and
  process-correct `AssetPackManager` acquisition for the SQLite plus sidecar.
- Added app-owned staging, SHA-256/size/schema/provenance/count/quick/FK/FTS
  validation, read-only and ATTACH denial, immutable release directories,
  atomic active/previous state, and automatic rollback after corruption.
- Added a pinned production pack command that validates all 2,597 entities,
  79,731 preferred localizations, 2,181 recipes, 4,003 ingredients, and 4,752
  content records before creating the Apple asset archive.
- Made the full generated production pair a Debug build prerequisite and moved
  the preview pair into test-only resources; Release bundle verification fails
  if either database file is present or the downloader extension is absent.

## Quick Wins (< 1 Week Each)

- Add a source badge to every result card: Packed, Live Atlas, or Community.
- Add the pack generation date beside the readable counts on Info.
- Add clear search filters for entity type, recipe kind, category, and rarity.
- Add a help/feedback sheet that exports app build, pack release, and failed
  query without exporting private user text by default.
- Add VoiceOver labels to placeholder icons and card provenance.
- Add a network-deny test that directly invokes every registered database tool
  and observes zero requests.
- Move preview fixture construction out of the Python test module and validate
  the committed preview on every verification run.
- Reconcile stale statements in deployment and ingestion documentation.

## Small Features (1–3 Weeks Each)

1. **Signed delivery rehearsal**: Register the shared app group for both bundle
   IDs, upload the validated archive, and rehearse first install, interrupted
   download, update, low storage, corruption, and rollback on physical devices.
2. **Complete local database-tool surface**: Keep the fixed
   `LocalDatabaseToolRegistry`, add the approved recipe detail/search, content
   payload, localization, and provenance tools, and prove each one against the
   production pack with networking denied.
3. **On-device model-planning boundary**: Add `SourcePolicyDecision`,
   `EvidenceLedger`, `AtlasModelPlanning`, `ProposedTurnPlan`,
   `DeterministicPlanner`, claim/action validation, and a native renderer. Make
   system-model selection explicit, expose precise runtime availability
   reasons, and unit-test both paths without requiring Apple Intelligence.
4. **Hosted CI quality gate**: Run Python tests, shell validation, pack fixture
   build, Swift unit tests, a generic iOS build, and app-bundle verification.
   Dependency: stable test target and selected Xcode runner image.
5. **Provenance-aware result model**: Carry source and release ID through every
   repository result and card. Define packed-over-live conflict behavior and
   compare recorded timestamps/release records rather than arbitrary SHAs.
6. **Onboarding and privacy consent**: Explain on-device model availability,
   deterministic fallback, optional live/web access, and exactly what leaves
   the device. Dependency: actual network behavior must be finalized first.
7. **Saved lists and export**: Let users group bookmarks into named plans,
   export a versioned file, and share individual deep links. Treat import as a
   separate untrusted-write feature with preview, confirmation, bounds,
   collision policy, atomic persistence, and rollback before enabling it.
8. **Accessibility and device-matrix pass**: Dynamic Type, VoiceOver order,
   contrast, reduced motion, iPad layout, oldest-supported-device performance,
   missing/corrupt pack, airplane mode, and model-unavailable scenarios.
9. **Transactional pipeline outputs**: Extend the pack builder's atomic publish
   pattern to transform artifacts, generated SQL plans, and asset receipts so a
   failed rebuild cannot mix stale success metadata with partial new files.

## Medium Features (1–2 Months Each)

1. **Grounded on-device conversation engine**: Complete the policy,
   model-planning, evidence-ledger, validation, and native-rendering split.
   Retain a bounded session context, stream and cancel progress, attach evidence
   IDs to claims/actions, handle guardrail/context/runtime errors, and
   regression-test behavior across supported OS model versions. No test or
   production path depends on a remote model.
2. **Recipe planner**: Traverse craft/refine/cook alternatives recursively,
   scale quantities, detect cycles, let the user choose a path, and save the
   resulting ingredient checklist.
3. **Fish and bait guide**: Implement the defined habitat, condition, time,
   size, mission, recipe, and bait contracts; keep recommendations
   condition-based rather than species-specific.
4. **Expedition archive and reward guide**: Normalize season and nested reward
   data, and keep packed history distinct from current web/live status. The
   source does not currently contain dates, availability, or milestone
   objectives.
5. **Release automation**: A protected manual workflow for source pin,
   transform, validation, Supabase activation, SQLite build, asset packaging,
   post-deploy checks, and rollback artifacts.

## Large / Strategic Features (2+ Months)

- **Personal play-session planner**: Combine saved items, recursive recipes,
  quantities, optional inventory, and progress into a practical session plan.
- **Broader typed reference library**: Promote building, ship, corvette,
  fossil, reward, story, and legacy families through the contracts and order in
  [SPECIALIZED_EXPERIENCES_PLAN.md](SPECIALIZED_EXPERIENCES_PLAN.md). Ship and
  corvette begin as catalogs/configuration notebooks; visual compatibility
  waits for a validated geometry/connection source.
- **Multi-language release packs**: Version localized search indexes and UI,
  with source-quality review and fallback rules per locale.
- **Platform expansion**: Consider web or Android only after the offline Apple
  product proves retention and the publication model is portable.

## Detailed Development Order

### Milestone 0 — Truthfully runnable baseline

Status: **Implemented in this build-out.**

Acceptance criteria:

- `prepare_ios_debug_pack.sh` plus a clean Xcode build produces an executable
  Atlas app backed by the complete pinned database.
- Full production SQLite/sidecar and the privacy manifest are present in Debug.
- Release excludes both bundled database files and embeds the downloader extension.
- SQLite quick/FK/FTS checks and exact production counts pass for Debug.
- Current Background Assets tooling accepts the pack manifest.
- Python pipeline tests pass.

### Milestone 1 — Correct offline internal alpha

Status: **Core retrieval and Library work implemented; tests/QA continue.**

Acceptance criteria:

- Network access and the on-device system model can be unavailable without
  losing item, recipe, feature search, deterministic answers, or saved
  navigation.
- All example questions in the app contract return relevant local cards.
- Library searches items, recipes, and feature records, and can browse beyond
  the first page.
- Errors are visible rather than converted silently to empty results.
- Entity -> recipe -> ingredient and feature-card -> feature-detail navigation
  work against the full production pack.
- The model tool registry contains only the documented local tools and can be
  constructed from `SQLiteNMSStore` without settings or network dependencies.
- Every registered tool succeeds against the full production pack with networking denied.
- Ordinary prompts, local misses, and local database errors create zero remote
  requests even when optional network settings have previously been enabled.

### Milestone 2 — Deterministic release and pack lifecycle

Status: **Managed runtime lifecycle, crash-consistent activation, and rollback
implemented; reproducible identity/source binding and signed-device rehearsal
remain pending.**

Implementation:

- Define `release_id` from source SHA, transformer SHA/version, contract
  version, and canonical artifact digest.
- Load source JSON from the resolved Git tree or compare every working copy
  input to its Git blob; reject dirty, foreign, or mismatched source roots.
- Make database import history append-only across transformer revisions.
- Inject or derive a reproducible build timestamp.
- Add minimum app build, pack schema, release ID, and SQLite SHA to the sidecar.
- Register signing/app-group capabilities, upload the asset archive, and run
  the lifecycle matrix on signed physical devices.

Acceptance criteria:

- Identical inputs create identical pack bytes.
- A claimed source commit cannot be paired with different source bytes.
- Corrupt, partial, and unsupported packs never replace the active pack.
- Missing-pack UI reports real progress and offers retry.
- The prior pack can be restored in a rehearsed test.
- The installed production pack contains the expected 2,597 entities, 2,181
  recipes, 4,003 ingredient relationships, and 4,752 feature records for the
  currently pinned release, with preferred localizations and FTS indexes.
- Every advertised database capability and model tool passes against that pack
  in airplane mode; a Release build containing the preview fixture fails.

### Milestone 3 — Grounded on-device Atlas beta

Status: **Typed retrieval planner implemented; model-planning lifecycle pending.**

Implementation:

- Introduce `SourcePolicyDecision`, `ActionPolicyDecision`, `EvidenceLedger`,
  `SourcedResult`, `ProposedTurnPlan`, `ValidatedAssistantTurn`, and resolved
  action types.
- Implement `AtlasModelPlanning` with an explicit
  `SystemLanguageModel.default` and a model-free `DeterministicPlanner`.
- Give the model only bounded conversation context and the fixed local read
  tool registry; do not give it network clients, settings, arbitrary SQL,
  mutating services, or unbounded history.
- Use guided generated claim/action proposals carrying evidence IDs, then
  validate and render facts from the referenced evidence before display.
- Report ineligible, disabled, not-ready, unsupported-locale, guardrail,
  context-window, and generation errors without losing the local answer.
- Keep a conversation session with compact evidence-aware history.
- Stream neutral progress; support cancellation, retry, and stale-response
  protection before enabling validated factual blocks and actions.
- Make web consent query-specific on first use and show durable source badges.

Acceptance criteria:

- Every factual sentence can be traced to a card/evidence record.
- Web text cannot become a canonical recipe.
- An eligible physical device produces a generative answer in airplane mode.
- No inference-network request occurs, and the production entitlements contain
  no Private Cloud Compute capability.
- Ineligible, disabled, not-ready, and unsupported-locale states return the
  same relevant records through deterministic narration.
- Optional Live Atlas/web retrieval never becomes an inference dependency or a
  canonical recipe source.
- Optional retrieval occurs only after explicit source intent and never because
  a local lookup returned zero rows or an error.

### Milestone 4 — Operations and internal TestFlight

Status: **Not started.**

Acceptance criteria:

- One protected manual workflow produces transform evidence, database release,
  SQLite pack, asset archive, and post-deploy verification.
- A failed import cannot modify the active release.
- Anonymous clients can read only approved public objects and cannot write.
- Internal TestFlight passes the offline smoke matrix on the oldest supported
  device, one system-model-ineligible device, and one eligible physical device.

### Milestone 5 — Public release gate

Status: **Blocked on product/legal decision, not engineering effort.**

Required decisions:

- Internal, public non-commercial, or commercial distribution intent.
- Rights and attribution posture for source code, structured game data,
  localization text, and imagery independently.
- Whether anonymous hosted access is permitted under that posture.
- Privacy policy, support contact, and user feedback retention rules.

## Test and Quality Matrix

| Layer | Required checks |
|---|---|
| Transform | Source-to-commit binding, nested shape validation, numeric ranges, schema drift, deterministic hashes |
| SQL import | Batch integrity, stable run identity, failed-import isolation, grants/RLS, representative query plans |
| SQLite pack | Input hashes/counts, contract compatibility, quick/FK/FTS checks, atomic publish, byte reproducibility |
| iOS store | Query planning, prefix search, recipe search, pagination, missing/corrupt/incompatible pack |
| Local database tools | Fixed registry allowlist, direct call of every tool, production-pack coverage, read-only/write/attach denial, release ID/provenance, zero requests under a network spy |
| Atlas answers | Advertised prompts, no-model fallback, evidence completeness, cancellation, web conflict policy |
| On-device model | Explicit system-model selection, all availability reasons, locale preflight, guardrail/context errors, evidence-ID validation, OS-model prompt regressions, airplane-mode physical-device run |
| UI | Navigation, saved persistence, empty/error/loading states, Dynamic Type, VoiceOver, iPad, airplane mode |
| Release | App executable/resources, no secrets, no bundled pack or cloud-model entitlement in production, asset archive, rollback rehearsal |

Provisional internal-beta budgets:

- Installed-pack ready state: under 2 seconds on the oldest supported device.
- Local search p95: under 200 ms on the production pack.
- On-device model-planned answer p95: under 8 seconds on the oldest eligible device;
  deterministic fallback p95: under 500 ms after pack readiness.
- Zero network calls with Live Atlas and internet search disabled.
- Zero network calls for local-source prompts, misses, and database errors in
  every settings combination; optional retrieval requires explicit source
  intent.
- Zero remote inference calls in every settings combination.
- 100% pass rate for the documented offline acceptance questions.
- Record time to first token, peak app memory, and thermal state during a
  20-prompt physical-device soak before setting final release budgets.

## Decisions Needed Before Scope Expands

1. Who is the first beta user: new player, returning player, or power crafter?
2. Is the first distribution internal TestFlight, public free, or commercial?
3. Does beta evidence support changing the default specialist sequence: recipe
   planning, fish/bait, expedition/building/ship catalogs, then broader
   collections?
4. Is the general web fallback important enough to maintain despite the
   fragility of HTML scraping?
5. Should bookmarks remain device-local for v1, or is iCloud sync a launch
   requirement?
6. Must unsupported hardware receive generative prose, or is the deterministic
   grounded answer and card experience acceptable for v1?

Unless beta evidence says otherwise, use this default: internal TestFlight for
returning players, recipe planning as the next differentiator, web search as an
optional beta feature, device-local saved data for v1, Apple’s on-device system
model where available, and deterministic grounded answers elsewhere. Do not
bundle a second model for v1 without device-coverage evidence.

## What Would Make This App Great

Atlas becomes great when it feels less like a database browser and more like a
trusted co-pilot beside the game: it answers immediately offline, shows exactly
where the answer came from, turns a desired item into a practical resource
plan, and never pretends uncertain community information is canonical. The
existing provenance and recipe graph make that product achievable without
accounts, a cloud LLM, or a sprawling platform build.
