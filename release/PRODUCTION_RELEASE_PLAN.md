# LiminalCreek adaptive shared study — production release review

**NOT DEPLOYED / NOT AUTHORIZED.** This is a reviewed release plan, not an instruction to execute immediately. Current real study data, the live Supabase project `fwdsoluixqeycapncecl`, and GitHub Pages `main` remain unchanged. Synthetic staging is a different project, `mrelwvpixalfycfdarjf`.

## Verified development work

- Hosted staging: 20 pairs at 50% adaptive based on 188 synthetic responses; then 30 pairs at 75% based on 235 responses.
- The second append preserved incomplete locations 117 and 120 and showed next set 121–150.
- Synthetic non-admin authorization, direct table privilege checks, participant batch transitions, and own-only progress RPC tested.
- The **exact guarded production migration** is tested in disposable PostgreSQL against a synthetic original 100-pair baseline.
- The updated `index.html` changes only: hidden administrator link/authorization check, and optional own-progress display. Existing questionnaire, `auth.js`, `sampling.js`, `sw.js`, participant RPCs and local prototype behavior are unchanged.

## Absolutely do not publish from this branch indiscriminately

Development contains staging-targeted `admin-adaptive.html`, `admin-adaptive-config.js`, `participant-staging.html`, `auth-staging.js`, synthetic SQL fixtures and test workflows. Merging the entire development branch would bring staging code into the production site.

The production GitHub Pages release must be an **atomic, curated two-file change on `main`**:
1. `index.html` copied from the reviewed development version.
2. `admin-adaptive.html` copied from `release/production-admin.READY-FOR-REVIEW.html`, with `PROD_DEPLOYMENT_ENABLED=false` changed to `true` **in the release artifact only, following explicit owner approval**.

The release admin page uses the normal site's existing signed-in Supabase browser session and the existing production **publishable** key from `backend/supabase-config.js`. Never embed service-role keys, production database passwords, staging keys, or synthetic account passwords.

Keep the existing production files `auth.js`, `backend/supabase-config.js`, `sampling.js`, `sw.js`, `manifest.webmanifest`, and other participant assets unchanged.

## Required production read-only readiness gate

1. Open the *existing live* Supabase dashboard and verify the project reference **`fwdsoluixqeycapncecl`**, not staging.
2. Run `release/live-readiness-inventory.READ-ONLY.sql` in its SQL Editor. Share only its aggregate result, never hidden response contents.
3. Expect one active unrevealed shared study, two participants, exactly one administrator, 200 assignments, 100 distinct matched pairs, zero invalid pairs/sequence duplicates/orphan responses, and eligible polygon parts.
4. Check the same database still has no `liminal_auto_batches` table and no adaptive admin RPC. If objects already exist, STOP and reconcile rather than rerun a migration.
5. Confirm the current eligible polygon shape, including any exclusion holes, is the intended study area. A current private original-pair snapshot may be checked **locally** with `node release/check-private-geometry.cjs /absolute/path/private-snapshot.csv` to confirm all original coordinates are eligible. The script outputs aggregate counts only, no private coordinates.
6. Confirm current site `main` has no unexpected newer changes compared with the reviewed main SHA. Stop on a conflict.

## Mandatory private backup before ANY production changes

- Confirm the existing Supabase project has a usable backup under **Database → Backups**, OR take a genuine logical database backup with the Supabase CLI `db dump`. Supabase Free projects do **not** have automatic daily backups.
- As an additional study-specific recovery copy, run `release/live-study-safety-copy.READ-ONLY.sql` in the *live* project; export the one-row result to a secure **private** local file. The result contains full real response notes and must never be pasted in ChatGPT or committed to GitHub.
- Record the approximate backup time and check its exported row counts (without sharing the contents). Ensure it is recoverable and not truncated.
- Exporting only the study rows is **not** a substitute for a complete database backup; it cannot restore Auth accounts, functions or all schema independently.

## Release order — only after a separate explicit GO decision

1. Re-verify the live readiness inventory and fresh private backups; record starting row counts and the current GitHub `main` commit.
2. Apply **only** `release/production-adaptive-migration.REVIEW-ONLY.sql` in the LIVE SQL Editor (once, with the reviewed contents). This is an additive transaction, fails closed on unexpected inventory, and does not add any new pair.
3. Verify `liminal_auto_batches` exists and is **empty**; RLS and table grants deny direct member access; `liminal_admin_commit_auto_batch` is executable by `service_role` **only**; `liminal_admin_auto_status` and `liminal_my_progress` are authenticated only.
4. Deploy **only** Edge Function `liminal-auto-activate` and shared engine to the explicit live project ref. Use the Supabase CLI with visible `--remote=fwdsoluixqeycapncecl` and `--use-api` and review the confirmation **target** before proceeding. Keep JWT verification **enabled**. Deployment itself makes no new assignment.
5. Stage and publish the curated two-file GitHub Pages release as one commit on `main` after verifying unchanged original `main` SHA. Do not merge all dev files. GitHub Pages hosting must be confirmed to use `main` before release.
6. Verify the participant interface still loads, sign-in and questionnaire work, and each participant's own-progress function returns sensible counts. A non-admin must not see or access the working admin control. On the administrator account, the Admin link opens the live production admin page, which shows current totals and readiness.
7. **Do not activate a new batch as part of deployment**. In a deliberate separate administrator action, choose 10/20/30/40 and the 50% or 75% adaptive preset. Only after readiness and backups have been verified should the administrator confirm.
8. After any activation, verify count increments, frozen batch metadata, retained older responses/assignments and uninterrupted next-location order. Check any live participant privacy concerns before enabling further batches.

## Failure / rollback discipline

- If a preflight fails, **STOP** and leave the study unchanged.
- If the database migration fails, it is transactional; do not rerun blindly.
- If the new function/UI misbehaves **before any activation**, revert only the curated new `main` UI files to their prior versions while retaining the existing live database and old collection RPCs. The added migration can remain dormant. Independently review Edge Function removal/disable if needed.
- If a batch was already activated, **never delete, renumber, or overwrite assignments or responses** in an attempt to roll back. The existing `next_liminal_place` and `submit_impression` RPCs remain valid for previously queued work.
- Never restore an old full database backup over newer participant responses without an explicit reconciliation plan. Preserve ongoing submissions.
- No access to the staging project is needed for production deployment, and no staging synthetic records should ever be copied.

## Known release caveats

- The live eligibility polygons are different from staging's synthetic rectangle. Real boundary geometry (and any holes) must be checked using the current private snapshot and/or a safe preflight; the Edge Function deliberately rejects existing pairs outside the stored study polygons rather than silently shifting them.
- The release production admin page is **disabled by default** in GitHub development; the separate GO-gated release artifact must explicitly enable it.
- If your existing project is on a Supabase Free plan, confirm you have made a manual database backup before running SQL.
