# Adaptive sampling and personal hotspot mapping (inactive draft)

**Not active; no live-study effects.** This folder contains experimental
planning code, tests, and a **DO-NOT-RUN** schema proposal. Nothing here is
loaded by the GitHub Pages app, connected to Supabase, or automatically
deployed as a database migration.

The live shared study uses next_liminal_place() and submit_impression()
in backend/02_live_study_api.sql. Both original participant assignment
queues and existing responses are immutable for this feature. **Never
regenerate or renumber the original 100 pairs.**

## Design agreed for the first adaptive phase

- Wait for **both participants to complete all their original 100 assigned
  locations**, even though their original order differs.
- Adaptive generation is private, periodic, and silent. Start with **10–15
  matched pairs per frozen batch**, each based on a recorded observation snapshot.
- Up to **200 ft** between paired locations for broad sampling; reduce
  separation for interesting/uncertain regions when useful.
- Indicative selection: 35% potentially interesting regions/peripheries;
  25% uncertainty or observer disagreement; 15% apparently uninteresting
  regions; 25% broad spatial controls. Configurable, not statistically optimized.
- A region qualifies for investigation based on **one participant's
  responses**; lack of evidence from the other isn't negative evidence.
- Preserve pair identity, opposite-observer blinding, and each participant's
  independently randomized order.
- Never show selection mode, model recalculations, or phase thresholds.
- Original 100 + roughly 100 adaptive pairs is a tentative target.
  More sampling can be *recommended*, never silently added beyond an
  approved final cap.
- Freeze each generated batch. Never move or overwrite assigned points.

## Required activation mechanism — NOT IMPLEMENTED HERE

1. Privately back up live studies, participants, assignments and responses
   and their row counts. Do NOT check private exports into Git.
2. Inventory all original pair IDs, coordinates, sequence numbers, and
   response rows, and record a comparison digest.
3. Verify both original queues have 100 assignments and that each
   participant really finished all 100.
4. Review and separately apply the proposed schema, with verified RLS.
   The DO-NOT-RUN SQL is **not** a migration to execute now.
5. Only in a trusted administrative service, read private observations and
   call adaptive-engine.generateBatch(). Store seeds, source snapshot and
   generated locations in a transactionally frozen staging batch.
   The browser MUST NOT read private responses.
6. Independently verify eligible-area containment, separation limit,
   uniqueness, and spatial distribution before promotion.
7. Promote each frozen batch atomically: append **new** assignments with
   sequence numbers strictly above 100, and above previous adaptive ones.
   Preserve all original rows and order; shuffle new pairs independently
   for each participant and assign the same pair ID to A/B. Never
   promote a batch twice.
8. Amend next_liminal_place() to distinguish an empty temporary queue from
   completion. Before activation, replace the live UI's "No more assigned
   places" text with a neutral waiting status when the plan remains open.
9. A trusted coordinator sets the **final pair target** and then formally
   closes the shared sampling plan. Each personal study requires the
   closed plan and that participant's completion of the final target.
10. Recheck inventory digest, privacy, and RLS immediately after each
    database change. Stop if historical rows change.

**No automatic generation, backend write path, schedule, schema migration,
or UI change is activated by this branch.**

## Personal mapping and joint reveal — later activation

Each participant's separate mapping plan uses **only their own** blinded
observations after completing the shared study. Regions reflect high
intensity regardless of type. The displayed boundary is broadened/softened.
Original exact sites, original intensities, notes, category-by-point
assignments, and partner observations remain hidden. Suggested feelings
are not ranked visually. At each new site choose a suggested feeling,
**Describe a new feeling** (adds a reusable choice immediately),
or **No particular feeling**, and rate the chosen feeling on **1–10**.
Optional free comments stay separate from original observations.

Personal mapping observations never influence the partner's blinded study.
A participant may complete or explicitly skip this optional phase.
Neither participant sees the other's data until a joint reveal.

The administrator's **Release shared results** button is **absent**
(not just disabled) until all of these are true:
- Sampling plan is finalized and closed.
- Both participants completed all assigned shared pairs.
- Both personal mapping sessions are completed or skipped.

Only then can an administrator confirm a server-side, transactional
reveal that checks these conditions again and simultaneously unlocks
results for both users. No administrator preview or early release UI.
The canReleaseResults helper is NOT a server authorization mechanism.

## Isolated tests

From repository root on Node 20+:

    node --test research/adaptive.test.js

Uses synthetic data, no Supabase calls or personal information.

## Limitations

- Sampling scores are exploratory information-gathering heuristics, not
  probabilities that any subjective impression is objectively true.
- Estimated additional sample size is a planning heuristic, not a
  validated power or stopping criterion.
- Spatial precision, observer-specific scales, time trends, differences
  in surroundings, and nonuniform adaptive-site inclusion probability
  must be considered in subsequent analysis.

## Administrator-adjustable adaptive percentage (draft)

The administrator may ultimately set **0–100% adaptive** for *future*
frozen matched batches. At **0%**, every newly selected pair uses broad,
spatially balanced randomized sampling with no response-informed location
selection; at **100%**, all newly selected pairs are adaptive. Intermediate
percentages reserve the complement for broad sampling. The algorithm divides
the adaptive fraction among potential hotspots (47%), uncertain/disagreeing
areas (33%), and quiet areas (20%); integer pair counts are rounded within
each batch. For small batches, percentages are therefore approximate.

The standalone preview is in `research/admin-sampling.html`. It is
**not** accessible through the currently deployed app and does not save
settings. When integrated, the control must check the authenticated admin's
membership on the **server**, use a protected settings RPC, and keep the
percentage secret from participant screens. A later change to the slider
must **never** rerun completed or already staged batches; only newly
generated batches can use a new percentage.

The percentage controls **sampling mix**, not study completion or automatic
extension. The administrator will separately approve more paired sites and
close the sampling plan before either person can start personal mapping.
No existing assignment is touched.
