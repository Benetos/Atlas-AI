# UI/UX Review — Atlas recipe plans

**Date:** 2026-09-05

**Scope:** Recipe plan, gather checklist, selected methods, alternative routes, and saved-plan refresh.

**Stack:** SwiftUI. Reviewed view code and the running iPhone 17 Pro Max simulator on iOS 26.5.

## Summary

The old plan expanded the first available refining recipe for every material. It followed a single chosen route, but nested resource conversions and loops produced excessive requirements. The screen listed every method group before the checklist, exposed internal identifiers in cycle paths, and did not explain the chosen crafting steps.

The revised default keeps crafting intermediates and gathers their raw inputs. Alternative methods require an explicit selection. Only the selected, reachable route contributes checklist requirements and method choices.

## Findings and changes

| Area | User impact | Implemented change |
| --- | --- | --- |
| Visual hierarchy | The gather list was buried below route controls and cycle paths. | Target summary, gather progress, and ordered crafting steps now come first. Route controls and source details are secondary. |
| Navigation and flow | Users could not identify which method generated the totals. | Every active item shows its chosen method. Expanded options show ingredients, output per batch, and a Selected marker. |
| Content clarity | Cycles showed identifiers such as PLANT_WATER and FARMPROD4. | Cycle paths use item names and explain that an ingredient must be gathered directly. Old snapshots fall back to available names instead of internal identifiers. |
| States and feedback | Old saved routes could retain the unwanted automatic refining choices. | Engine updates preview the new gathering defaults. The original saved plan remains intact until the user creates a new revision. |
| Accessibility | Dense quantities and controls made plans difficult to scan. | Quantities use digit grouping; checklist controls retain 44-point targets, spoken gathered status, and a visible progress count. |

## Verification

- 59 focused simulator tests passed, including exact full-pack Circuit Board totals, explicit refining replacement, inactive-route pruning, readable cycle paths, and old saved-plan preservation.
- The default 12 Circuit Board plan gathers 1,200 Frost Crystal, 2,400 Solanium, 1,200 Cactus Flesh, and 2,400 Star Bulb. It then makes 12 Heat Capacitors and 12 Poly Fibres before crafting 12 Circuit Boards.
- In the running simulator, selecting the Dioxite/Oxygen refining method replaced 1,200 Frost Crystal with 2,400 Dioxite and 1,200 Oxygen. Other crop requirements and checked progress stayed intact.
- The unsigned physical-device build and app bundle verification passed.

## Preserved behavior and limits

Checklist marking, item detail links, save/update controls, and saved revision protection remain available. Explicit refining choices can still create loops; these are bounded and displayed with readable warnings. The planner uses the installed recipe snapshot and does not claim to optimize for inventory, growing time, or the cheapest route.
