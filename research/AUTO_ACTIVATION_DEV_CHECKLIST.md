# Shared adaptive activation — off-production rollout checklist

**Status:** Development only. Nothing in this branch has been deployed to the live study.
**Study:** Shared, blinded two-person sampling only. The personal hotspot experiment is separate.
**Production restriction:** DO NOT execute the draft SQL or deploy the Edge Function to the live Supabase project without the owner's later explicit approval.

## Intended administrator experience

The existing participant application retains its appearance, questions, daily limit, and `next_liminal_place` / `submit_impression` RPCs. A link labelled **Admin** is revealed in the app header only after a successful server-side administrator check. The standalone `admin-adaptive.html` screen is otherwise inaccessible to unauthenticated users or non-admin study members.

When at least 100 original pairs have been assigned to both participants, the administrator can queue **10, 20, 30, or 40** new pairs before either participant finishes their current set. The admin selects a **50% or 75% adaptive** sampling preset and confirms. The system permits one upcoming unstarted batch at a time; a second cannot be stacked until at least one participant begins the queued batch. The server then:
1. Rechecks the authenticated JWT and study administrator role.
2. Reads existing paired assignment coordinates and available valence/strength observations privately. It does not read comments, description text, or email addresses.
3. Generates the chosen number of pairs in one batch with the selected sampling ratio. Defaults remain 50% adaptive for the first 40 additional pairs, then 75% adaptive, but the administrator can override the preset. The engine uses **all sites already assigned** to avoid repeated coverage, and **only responses actually submitted** as adaptive evidence; pending responses are not imputed as neutral.
4. Checks the eligible polygons (including holes), paired separation, counts and identities.
5. Creates independent presentation orders and invokes the **service-role-only** commit RPC.
6. In one transaction, freezes the exact generated candidate data and appends both participant queues. Existing assignments and responses are not updated.
7. Returns only batch metadata to the administrator browser. No coordinates or participant observations are returned.

The *previous* offline, map-reviewed 20 are test proposals. They are **not** automatically deployed. The operational engine generates from the freshest observations when the administrator activates a batch. Once committed, the exact generated locations are frozen in a private batch record and are not regenerated.

## Files

- `index.html`: admin-link only; participant UI and submission workflow otherwise unchanged
- `admin-adaptive.html`: administrator current-set progress, 10/20/30/40 count dropdown, 50/75 adaptive preset dropdown, and append controls
- `research/admin-offline-preview.html`: self-contained offline visual preview with synthetic 116/120 and 119/120 progress; no database connection
- `admin-adaptive-config.js`: deliberately blank connection settings on this development branch; the administrator page is **disabled** until explicitly set to an isolated staging project
- `supabase/functions/liminal-auto-activate/index.ts`: private Edge Function, JWT and administrator checks, generation, retry check
- `supabase/functions/_shared/adaptive-engine.mjs`: shared adaptive selection engine (not the personal hotspot engine)
- `research/drafts/auto-activation.DO-NOT-RUN.sql`: new private batch table, admin status RPC, atomic server-only commit RPC
- `research/tests/auto-activation-smoke.sql`: disposable-PostgreSQL tests
- `research/admin-ui-contract.test.js`: participant UI and administrator-only integration checks
- `research/edge-engine-parity.test.mjs`: selected-site generator parity and 20/40 mix tests

## Tests already available on the development branch

1. Pure JavaScript synthetic sampling tests, including parity of the private Edge engine with the studied shared engine.
2. Deno type check of the Edge Function (no Supabase keys).
3. Disposable PostgreSQL tests for administrator authentication, service-only coordinates commit, proactive activation from 88/100 and 100/100 original completions and later 116/120 and 119/120, selected preset ratios, independent sequence permutations, idempotence, and preservation of original responses and assignments.
4. Static administrator page tests and checks that participant collection functions are not replaced.

**These do not constitute a full Supabase integration test.**

## Mandatory next verification — isolated Supabase staging

- Create a completely separate Supabase project. Do not clone production data, auth accounts, assignments, participant emails, or secrets.
- Configure **only** `admin-adaptive-config.js` with the staging project's public URL/publishable key during staging. It is blank by default. Never point a development administration page at the production project.
- Before browser-testing the participant app itself, replace the copied `auth.js` project settings with **staging** settings in an isolated staging build. The source `auth.js` currently retains the live app's production settings and must not be exercised against the live study during development.
- Apply a fresh copy of the relevant study schema, existing live collection API, then the proposed adaptive draft **to staging only**.
- Use two synthetic test identities (one designated admin). Insert 100 synthetic matched pairs and mock responses through controlled fixtures.
- Deploy the Edge Function only to staging, with staging-specific keys. Verify administrator status is denied to non-admin, public/anonymous clients cannot read responses, and both participant apps remain blinded.
- Verify 10, 20, 30, and 40 pair actions end-to-end through the real browser and Supabase client, with both selectable adaptive ratios and **unfinished** current sets, including role claims, CORS, `auth.role()`, and response/assignment counts.
- Simulate network timeouts, concurrent requests, duplicate request IDs and refreshed admin sessions. Confirm no double append.
- Verify the original 200 assignment records and 200 synthetic responses are **byte-for-byte unchanged**, including order, identifiers and notes.
- Confirm each user's locations follow independent orders and a user cannot retrieve a matched partner's coordinates or the other person's answers.
- Test final participant UI visually and behaviorally, including the daily limit and session login/logout. The administrator link must never appear for the non-admin.
- Verify all new objects have RLS and no browser table grants, and the commit RPC is executable by `service_role` **only**.
- Rehearse rollback in staging. The live study must never be rolled back by deleting original records.

## Production gate — requires separate owner approval

1. Validate a fresh read-only production permissions inventory. Obtain and verify a fresh database backup, including participant comments and existing responses.
2. Pause while assessing the latest development and deployed versions to ensure no unrelated participant UI change is being merged.
3. Apply only the reviewed additive migration and Edge Function, then the reviewed admin-only app update, after explicit go-ahead. The production admin connection settings must be enabled as part of that separate, explicitly reviewed release; the development branch's default stays disconnected.
4. Test administrator status before any activation. Record production counts and hashes before and after.
5. **Do not activate any new locations automatically during deployment.** The administrator deliberately selects 10/20/30/40 and a preset ratio. This can happen before current assignments are complete, but new locations are appended after them. No individual location approval is required.
6. Never reveal hidden participant responses, comments or partner locations before the planned study conclusion.

## Privacy and failure behavior

- All test fixtures on GitHub must be synthetic. Never upload `snapshot.csv`, `preview.json`, generated coordinates, real response intensities or live service-role credentials.
- Activation uses a UUID request ID to support idempotent retries; the administrator page retains only the pending request ID and count in browser session storage.
- The browser cannot submit location coordinates. The private commit RPC is callable only by `service_role` and checks the verified user's administrator membership.
- The database checks the latest assignment/response counts again in the same transaction as insertion. If they changed during generation, the operation fails without partial assignment insertion.
