# Final focused batch — staging/release instructions

**Status: UNRELEASED.** Do not deploy this feature to the live Supabase project or GitHub Pages main until an explicit new approval. No focus-area coordinates or saved candidate sites are stored in this public branch.

## Intended final workflow
- Authorized administrator uses the same existing login and opens the admin page.
- Chooses the **Final focused batch** panel and locally uploads the existing two-polygon prototype export (.json/.geojson).
- Chooses **Generate and add FINAL 20 matched pairs** and confirms. Exactly 10 pairs are selected in each polygon, randomly but with dispersion constraints, independent of participants' responses.
- The Edge Function intersects each supplied polygon with the official active study eligibility geometry (including holes), avoids all already assigned A/B points, and generates both pair endpoints inside the *same* source polygon. Each matched pair is 10–19 m apart (well under 200 ft). All generated sites remain server-side.
- Two independently randomized sequence permutations are stored atomically with the 20-pair manifest in the private `liminal_auto_batches` table. The original assignments, submitted responses and blinded observations remain unchanged.
- The batch is flagged `focused_final`; the status RPC disables future administrator additions and the database INSERT trigger prevents even trusted-server accidental post-final appends.
- Participants continue their existing unanswered locations before the final focus set. Actual study reveal remains a SEPARATE manually authorized action after both have finished.

## Do not activate early
The existing queued-batch safeguard remains: if the most recently assigned batch has not yet been started by either participant, a new batch cannot be added. This allows the focus round to be deliberately placed last, not inserted prematurely.

## Minimum staging checks before release
1. Use the existing separate synthetic Supabase project, not live production. Apply `release/final-focused-migration.REVIEW-ONLY.sql` in staging **once** after confirming its original adaptive schema. No migrations or app updates should run in production for this test.
2. Deploy the feature branch Edge Function **explicitly to staging only**, with JWT verification enabled.
3. In a local staging admin page, upload a **synthetic** two-polygon export inside the synthetic study area's rectangle (not the user's real private focus polygons). Test generation, 10/10 allocation, both assignments/response preservation, idempotence, non-admin rejection, and that further additions are blocked after marking final.
4. In an isolated SQL transaction or read-only verification, confirm pair endpoints remain within both the synthetic target polygons and the official eligible area, all old responses remain, and no unstarted batch was bypassed.
5. Once staging passes, verify a fresh restore-tested private GitHub backup and review live inventory again.
6. Deploy to production in THIS order, only after explicit owner go-ahead: additive `final-focused-migration.REVIEW-ONLY.sql`, verify grants and no new rows, deploy the updated Edge Function to the explicitly named live project, and atomically publish only the reviewed `admin-adaptive.html` update. The participant `index.html` is unchanged by this feature.
7. Keep the final focus button untouched until the owner actually wants to queue the last set; no activation is part of deployment.

## Security and backup
- Supabase trusted server is the only role able to commit final batch records. No service-role secret in the browser.
- Upload is local until a deliberate admin activation. No raw candidate locations, old participant answers or target polygons are posted to public GitHub.
- The private backup repository archives the full public-schema data and has restore tests. Capture a fresh one before the actual production migration.
- If live migration fails, stop; don't rerun blindly. If final batch was activated, NEVER delete or renumber participant assignments: preserve data and reconcile any problem manually.
