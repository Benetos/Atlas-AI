# Agent notes

Atlas is a **solo-developer** repo. Do not split work into stacked review PRs
(Phase 1A / 1B / 2, “merge this then that”). One task gets **one branch** and
at most **one PR** against `main`. Phases in
[docs/SPECIALIZED_EXPERIENCES_PLAN.md](docs/SPECIALIZED_EXPERIENCES_PLAN.md)
are implementation order, not pull-request boundaries.

Prefer checking out or merging the tip that contains the slice. Extra base
branches exist only as leftover process from the first planner stack; do not
repeat that pattern.

## Standing product decisions

Do not re-litigate these. If a later concrete defect appears, backtrack then.

- **Publication / Hello Games material:** The owner has already covered image
  and publication issues. Use packed structured data, localization text, and
  referenced icons in the app. Do not keep asking for a legal writeup, and do
  not leave placeholders in place of available icons.
- **Facts only:** Show condition, time-of-day, storm, mission, and bonus fields
  when they exist on the packed record. Do not speculate (no invented
  species-specific bait, ship assembly, or “current expedition” from historical
  rows).
- **TestFlight gate:** Typed pack projections **and** usable specialist UI
  (shared collection/detail/compare-or-checklist shell plus a richer Library)
  land before TestFlight. Cooking uses existing recipes. Ship/corvette parts
  are in; assembly claims are out. Expedition archive UI can wait; expedition
  rows may still be packed.
