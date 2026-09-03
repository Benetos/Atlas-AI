# Atlas Work Slices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Atlas a phone-local NMS companion and implement the next player jobs as independent slices, starting with a recipe planner and a versioned local saved-data store that can sync later.

**Architecture:** The installed SQLite pack remains the only handbook. New features read `SQLiteNMSStore` and write versioned local artifacts. Optional user-data sync is a later upload of those artifacts to Supabase or Firebase. Live handbook HTTP is parked.

**Tech Stack:** SwiftUI / iOS 26, on-device SQLite pack, local Application Support store, optional later hosted user-data API.

## Global Constraints

- Canonical facts come only from the installed read-only SQLite pack.
- No cloud language model. No live-handbook fallback for a local miss.
- One developer; verify on a local checkout and on the phone. Hosted CI is not required.
- Saved player data stays on the device until Slice 8 is explicitly started.
- Attribution stays in Info. Atlas does not claim to own Hello Games material.
- Do not copy NMS-Handbook Python or website files into the app.
- Do not estimate calendar time. Size work by files, dependencies, and done checks.

---

### Task 0: Documentation already records the slice order

**Files:**
- `docs/WORK_SLICES.md`
- `docs/superpowers/specs/2026-09-03-atlas-work-slices-design.md`
- `docs/APP.md`
- `docs/feature-roadmap-Atlas.md`
- `docs/SPECIALIZED_EXPERIENCES_PLAN.md`
- `docs/ROADMAP.md`

**Status:** Completed by this documentation pass.

---

### Task 1: Recipe graph engine

**Files:**
- Create: `apps/ios/Atlas/Planning/RecipePlanEngine.swift`
- Create: `apps/ios/Atlas/Planning/RecipePlan.swift`
- Test: `apps/ios/AtlasTests/RecipePlanEngineTests.swift`
- Read: `apps/ios/Atlas/Store/SQLiteNMSStore.swift` (`recipesProducing`, `recipesUsing`)

**Interfaces:**
- Consumes: `NMSStore.recipesProducing(type:id:limit:)`, `NMSStore.recipesUsing(type:id:limit:)`, `NMSStore.recipe(id:)`
- Produces: `RecipePlan` with `target`, `quantity`, `selectedPathIDs`, `lines`, `totals`, `cycles`, `packReleaseID`, `engineVersion`

- [ ] **Step 1: Write failing tests for a known Circuit Board expansion and a cycle**

Use the full hosted pack. Assert a quantity of 12 scales ingredient totals exactly, and a synthetic cycle fixture returns a typed cycle error instead of hanging.

- [ ] **Step 2: Implement a bounded deterministic traversal**

Bounds: depth 12, five alternatives per node, 500 visited nodes. Arithmetic is overflow-checked. The model never runs inside this type.

- [ ] **Step 3: Run `AtlasTests` for the new class and commit**

---

### Task 2: Versioned local artifact store

**Files:**
- Create: `apps/ios/Atlas/Store/SavedArtifactStore.swift`
- Create: `apps/ios/Atlas/Store/SavedArtifact.swift`
- Modify: `apps/ios/Atlas/Store/SavedStore.swift` (migrate, then thin wrapper or delete)
- Test: `apps/ios/AtlasTests/SavedArtifactStoreTests.swift`

**Interfaces:**
- Consumes: current `atlas.savedItems` / `atlas.recentItems` UserDefaults keys
- Produces: `SavedArtifactStore` actor with `load()`, `upsert(_:)`, `delete(id:)`, `migrateFromDefaultsIfNeeded()`

Artifact envelope:

```swift
struct SavedArtifactEnvelope: Codable, Sendable {
    var storeSchemaVersion: Int
    var artifactID: String
    var kind: SavedArtifactKind
    var payloadVersion: Int
    var createdAt: Date
    var updatedAt: Date
    var packReleaseID: String?
    var checksum: String
}
```

Kinds: `bookmark`, `list`, `note`, `recipePlan`, `guideProgress`.

- [ ] **Step 1: Write failing tests for migrate-once, corrupt-file quarantine, and relaunch restore**
- [ ] **Step 2: Write an atomic Application Support store; leave old defaults until the new file reopens cleanly**
- [ ] **Step 3: Point Saved tab bookmarks at the new store and commit**

Payload JSON must stay uploadable later without a rewrite. Do not add a network client here.

---

### Task 3: Planner screens and save

**Files:**
- Create: `apps/ios/Atlas/Views/RecipePlanView.swift`
- Modify: `apps/ios/Atlas/Views/RecipeDetailView.swift`
- Modify: `apps/ios/Atlas/Views/AtlasView.swift`
- Modify: `apps/ios/Atlas/Views/SavedView.swift`
- Modify: `apps/ios/Atlas/AppModel.swift` (`AtlasRoute.plan`)

- [ ] **Step 1: Quantity, path picker, totals, and checklist UI against fixture plans**
- [ ] **Step 2: Save/restore through `SavedArtifactStore`**
- [ ] **Step 3: Add an Atlas action from a recipe answer: “Open plan”**
- [ ] **Step 4: Run on the phone: create a plan, force-quit, reopen, confirm progress**

---

### Task 4: First specialist family (only after Tasks 1–3)

Pick fish/bait unless a different packed family is suddenly more useful.

**Files:**
- Modify: `scripts/build_nms_sqlite.py` (additive typed tables, new pack schema version)
- Create: Swift DTOs + store queries + collection/detail views
- Test: 100% decode of that family on the production pack

Follow [SPECIALIZED_EXPERIENCES_PLAN.md](../../SPECIALIZED_EXPERIENCES_PLAN.md) for source rules. Do not invent facts the pack does not have.

---

### Task 5: Optional user-data sync (do not start early)

**When:** Local lists and plans are something a player would miss on a second device.

**Files (later):**
- Create: `apps/ios/Atlas/Store/UserDataSyncClient.swift`
- Modify: `SavedArtifactStore` with a sync cursor / dirty flag
- Hosted: one user-data project — free Supabase **or** Firebase, not both

Rules:

- Sync only Slice 2 artifacts.
- The phone store works with the network off.
- Last-write-wins per `artifactID` until a real multi-device conflict appears.
- Never upload the SQLite pack, prompts, or model output as the handbook.

---

## Execution order

```text
Task 1 recipe engine
  -> Task 2 local artifacts
  -> Task 3 planner UI
  -> Task 4 one specialist family
  -> later slices in docs/WORK_SLICES.md
  -> Task 5 only if sync is wanted
```

Skip live Atlas restoration, hosted CI, and backend selection until Task 5.
