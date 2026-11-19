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
- Adaptive generation is private, periodic, and silent, using **20
  matched pairs per frozen batch** based on a recorded observation snapshot.
- After both complete the original 100, run a **response-blind geographic
  coverage audit** of all A and B assignment coordinates against the exact
  eligible-area polygons (including exclusions). Report nearest-assignment
  distances, median/90th-percentile distances and estimated area fractions
  farther than 50/100/150/200 m from any assigned location. Also report
  per-participant coverage separately and privately locate large gaps.
  Unknown/unvisited territory is **not** evidence of a quiet feeling.
- Proposed default transition, for **100 approved additional matched pairs**:
  - Pairs **101–120**: 10 response-blind, coverage-directed controls +
    10 response-informed investigations (50:50).
  - Pairs **121–140**: another 10 + 10, re-auditing geographic holes first.
  - Pairs **141–200**: 15 response-informed + 5 coverage-directed controls
    per 20-pair batch (75:25). Thus the full 100-pair extension includes
    65 response-informed and 35 coverage-directed controls.
  This is a **proposed default**: it does not silently authorize additional
  locations, change previously frozen batches, or auto-close the study.
- "Coverage-directed" is deliberately **not uniformly random**, although
  it is selected without using anyone's impression data. It preferentially
  fills the largest geometric gaps, using independent random seeds and candidate
  pools. Call these response-blind spatial controls, not unqualified random
  samples; record their selection mode for subsequent inference.
- Up to **200 ft** between paired locations; use smaller separations for
  some response-informed investigations when useful.
- Within the response-informed portion, target potentially interesting local
  hotspots and peripheries (~47%), uncertain or locally contrasting pairs
  (~33%), and genuinely observed quiet regions (~20%). The new short-range
  score prevents one strong response being lost within a broad neighborhood
  of neutral ratings. A matched A/B contrast can represent geography as well
  as participant differences: do not call it proof of observer disagreement.
- A region qualifies for investigation based on **one participant's
  responses**; lack of evidence from the other isn't negative evidence.
- Preserve pair identity, opposite-observer blinding, and each participant's
  independently randomized order.
- Never show selection mode, model recalculations, or phase thresholds.
- Original 100 + roughly 100 adaptive pairs is a tentative target.
  More sampling can be *recommended*, never silently added beyond an
  approved final cap.
- Freeze each generated batch. Never move or overwrite assigned points.

## Two additional pure draft utilities

- `research/coverage-audit.js` exports `auditCoverage()`, a deterministic
  and **response-blind** diagnostic, and `phasePlan()`, the 50% → 75%
  proposed default. Both operate on trusted geometry/assignments and make
  **no database calls or writes**.
- `research/adaptive-engine.js` now selects broad controls from a separate
  response-blind candidate pool **before** response-informed proposals, then
  shuffles the finished pairs. Changing response strengths/valences without
  changing assignment geography cannot change broad control coordinates.
  It also uses a short-range strong-response feature and localized matched
  pair contrasts for targeting.
- `research/coverage-audit.test.js` checks exclusion zones, deterministic
  coverage estimates, improvement of synthetic geographic gaps, and phase
  boundaries. `research/adaptive.test.js` checks independent controls and
  sensitivity to an isolated strong response. These tests use **synthetic
  data**, not the live study.

The administrator prototype and draft SQL **do not yet apply this phase
schedule automatically**. The eventual trusted coordinator must read the
approved pair limit, count completed/released assignments, freeze each batch's
sampling settings, and enforce the transition. Initial geographic coverage
can be audited privately from the assigned coordinates even before 100
responses, but adaptive promotion must wait until **both** complete 100.
Re-run coverage analysis between batches without changing previous points.

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
are not ranked visually. The personal study uses **paired relative comparisons**, not 1–10 ratings.
Each question presents two dots (one previously sampled reference, one new
location) and a chosen feeling, asking which feels stronger. Which dot is
the reference is random and concealed. Answers: A, B, equally strong,
neither, or different character without a clear stronger choice. **Describe
a new feeling** adds a reusable choice. Original 1–4 ratings are used only
to nominate candidate regions and possible feeling labels; after the mini-
study begins, spatial updates are driven by the comparison responses alone.
The old ratings must never enter personal-study ranking, weighting, or
prediction. Personal comparisons remain distinct from shared observations.
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

    node --test research/*.test.js

Uses synthetic data, no Supabase calls or personal information.

## Limitations

- Geographic-coverage fractions are **Monte Carlo estimates**, not proofs
  that every part of a polygon has been visited; smaller spatial gaps can
  remain. Use the same seed and sample grid for before/after comparisons.
- The nonuniform, adaptive/coverage-directed design changes inclusion
  probabilities. Retain sampling modes, seeds, snapshots and exact selection
  settings for later analyses.
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

## Administrator dashboard and batch release (October 2026 draft)

The branch-only `research/admin-sampling.html` is now wired to proposed
administrator RPCs defined in `research/drafts/admin-rpcs.DO-NOT-RUN.sql`.
These RPCs are **not installed in Supabase**. The dashboard is therefore
not live or usable until a separate, reviewed deployment.

- Administrator-only progress: counts completed/assigned for each participant,
  including counts from the immutable original 100. Never exposes observations,
  notes, partner coordinates, or individual impression categories.
- Future settings: 0–100% adaptive sampling and 1–30 pairs per batch
  (default 20). Settings change **future batches only**.
- Explicit study extension: an administrator authorizes the **total number of
  matched pairs**, initially 100. Merely authorizing does not generate/release
  anything. A frozen batch cannot exceed the current authorization limit.
- Batch release: the administrator supplies a reviewed frozen batch UUID.
  The RPC checks both original 100 queues are complete, verifies stage order,
  appends the same staged pair identifiers to both participants' queues in
  separately frozen orders, and marks the batch released atomically.
- Nothing can be released twice; already assigned and answered points remain
  untouched. The private coordinator that securely generates and freezes
  batches from real polygons/observations is still **to be implemented**.
- A new waiting-for-next-batch state is also needed in the live collection UI
  before actual activation, along with privacy/regression tests in a
  disposable Supabase database. Do not install these draft RPCs in production
  or merge this branch without those steps.

The existing private daily backup workflow remains independent.

## Participant interface and confirmation safeguards

The shared participant interface (`index.html`, `auth.js`) is unchanged by
this branch. The administrator screen is an entirely separate page in the
inactive research folder. Before integration, show its entry only after an
authenticated server-verified administrator role check. Never load it for or
provide navigation to non-admin participants. The server, not a hidden tab,
must prevent non-admin access. No participant will see the administrator
statistics, planned percentages, staging IDs, or partner's individual results.

**Two different meanings of “release”:**
1. **Release a new location batch**: append reviewed matched locations to
   two separate participant queues. The draft admin page now requires opening
   a separate review panel, then correctly entering the frozen batch UUID;
   server-side membership/completion/limit/duplicate checks are still required.
2. **Share/reveal study responses**: future, sensitive and conceptually
   separate. This is not implemented. Two disabled controls indicate a
   mandatory *preview of exactly what would be shared* and a separate
   *verified approval* step. We must agree what is shared, with whom, and when,
   before implementing any reveal. A simple browser confirm or typed phrase
   alone is not adequate authentication for actual data disclosure. The
   final server-side flow should require fresh authentication, a short-lived,
   single-use confirmation bound to an immutable disclosure manifest, and
   re-verification of the shared-study closure and both personal phases.
   Nothing in this branch grants access to private responses.
