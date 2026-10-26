# LiminalCreek adaptive sampling — personal field test (v0.1)

## Scope / safety boundary

- **Active personal test:** `personal-field-test.html` imports `adaptive-sampling-engine.js` and uses it for new questions.
- **Archived baseline:** `personal-field-test-pre-adaptive-20261025.html` preserves the prior, non-adaptive working interface.
- **Shared blinded study:** `index.html`, Supabase, study assignment tables, RLS, and shared-study adaptive draft are **unchanged**. This JavaScript library does not connect to any server and does not access blinded study data.

## Architecture

`adaptive-sampling-engine.js` exposes `window.LiminalAdaptive`:

- `SpatialModel(area, observations)`: multiscale radial-basis latent spatial surface with approximate Bayesian updates and predictive uncertainty. Works with the `PersonalAdapter`'s pairwise observation format. The statistical core is separate from map UI, local storage, and pair-generation rules.
- `PersonalAdapter(area, {maxDistance, random})`: interprets one user's A/B, similar, neither, and optional ordinal magnitude answers; selects candidate pairs inside an allowed polygon. Enforces 152.4 meters (500 feet), minimum pair separation, and recent-location spacing.
- `PersonalAdapter.propose(history, feeling)`: returns `{A,B,referenceIsA,sampling}`. `sampling` contains objective (`explore`, `peak`, `gradient`, `valley`), distance, sample count, estimated difference, and uncertainty. These diagnostics are preserved in the export.

Broad and fine spatial bases allow different scales. Sampling priorities gradually shift with **both** the number of observations for that feeling and the strength of the inferred spatial variation. Very occasionally, after an `equal` response between nearby points, a gradient-sampling opportunity is replaced by a pair approximately **perpendicular** to that equal pair. This checks for a contour/gradient without interpreting equality as evidence of strong intensity. A valley pair only becomes a `peakValleyCalibrationCandidate` if both inferred flanking peaks and their intervening depression have local observations and sufficient model separation; the flag does not certify that the peaks/valley truly exist. The code otherwise retains its prior sampling objectives and weights.\n\nThe code uses heuristic, uncertainty-aware candidate scoring; it is **not** a formal mutual-information optimizer or validated Gaussian-process posterior. The `valley` strategy probes connections between separated promising regions; it **does not yet certify** local maxima or saddle points.

A/B provides a noisy order constraint, both similar provides a noisy equality constraint, and neither supplies low-association evidence for both locations. Ordinal strengths condition relative differences on **ordered intervals**, not equidistant numeric labels. Thresholds and observation noise are provisional and require empirical validation. Predicted latent units must not be interpreted as calibrated absolute feeling intensity.

## Personal test integration

- The existing 1987 aerial overlay, tighter polygon, four selectable feelings, map-level four answers, managing-feelings dock, and rotating feeling notification remain.
- Roughly 10% of A/B selections ask **Slightly / Noticeably / Much stronger**, with Skip. Most prompt opportunities are independent random draws (13% chance when the eight-comparison cooldown permits). A small additional chance (3.8%, only after the random draw fails) is reserved for a model-supported peak–valley contrast, *not* all peak or gradient probes. Even if every pair qualified, the expected fraction of targeted prompts would be about 20%; in ordinary data it should be lower. Each prompted response records `magnitudePromptSource: "random" | "peak-valley"`. The original A/B response is saved **before** the optional popup; unfinished calibration resumes after reload.
- A new local-storage namespace `liminal-personal-adaptive-fieldtest-v1` provides a **fresh test** without overwriting the prior version's `liminal-personal-independent-fieldtest-v2` answers. Back up/export the old test if needed. The new JSON export retains response metadata, sampling diagnostics, and optional magnitude responses.
- Reload restores an unfinished pair, magnitude popup, or scheduled feeling-change notice as appropriate; resetting affects the **new adaptive test only**.

## Validation

`node adaptive-sampling-engine.test.js` runs deterministic synthetic tests of polygon containment, the 500-foot cap, repeat-safe candidate generation, all adaptive proposal objectives, uncertainty finiteness, tie/absence observations, and a simulated hotspot. A separate isolated mock-browser test exercised first-time setup, 40 completed responses, two magnitude popups, two feeling rotations, and continued pair generation without accessing production. Browser-level visual testing on actual GitHub Pages remains to be done.

## Before any shared-study reuse

**Do not deploy this PersonalAdapter or response model directly to the shared study.** First review the separate existing adaptive shared-study code, research objectives, blinded assignment protocol, matched near-but-distinct locations, coverage of neutral/cold regions, independent participant views, quotas, completion/reveal safeguards, and appropriate absolute-impression observation models. Reuse the tested geometry/uncertainty machinery where it genuinely fits; build a separate shared-study adapter and validate against its own constraints. No migration, merging, or activation is implied here.

## Future refinement priorities

- Compare sequential approximate Bayesian fitting with stronger posterior inference and held-out predictions.
- Explicitly identify peak pairs, intermediate saddles/valleys, and uncertainties, then test alternative connecting paths.
- Calibrate magnitude thresholds and assess whether follow-up questions improve predictions.
- Tune exploration/refinement schedules from real participant experience and support principled stopping conditions.
