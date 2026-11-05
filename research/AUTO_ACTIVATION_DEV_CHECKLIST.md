# Shared adaptive activation — off-production rollout checklist

**Status:** Development only. Nothing in this branch has been deployed to the live study.
**Study:** Shared, blinded two-person sampling only. The personal hotspot experiment is separate.
**Production restriction:** DO NOT execute the draft SQL or deploy the Edge Function to the live Supabase project without the owner's later explicit approval.

## Intended administrator experience

The existing participant application retains its appearance, questions, daily limit, and `next_liminal_place` / `submit_impression` RPCs. A link labelled **Admin** is revealed in the app header only after a successful server-side administrator check. The standalone `admin-adaptive.html` screen is otherwise inaccessible to unauthenticated users or non-admin study members.

Once **both participants have responded to every currently assigned location**, the administrator selects **20** or **40** new paired locations and confirms the action. The server then:
1. Rechecks the authenticated JWT and study administrator role.
2. Reads existing paired assignment coordinates and available valence/strength observations privately. It does not read comments, description text, or email addresses.
3. Generates 20-pair chunks with the shared engine, using 50% response-informed selection during the first 40 additional pairs, then 75% thereafter. A 40-pair choice uses the first 20 proposals to improve coverage before generating its next 20; it does not invent responses that have not been collected.
4. Checks the eligible polygons (including holes), paired separation, counts and identities.
5. Creates independent presentation orders and invokes the **service-role-only** commit RPC.
6. In one transaction, freezes the exact generated candidate data and appends both participant queues. Existing assignments and responses are not updated.
7. Returns only batch metadata to the administrator browser. No coordinates or participant observations are returned.

The *previous* offline, map-reviewed 20 are test proposals. They are **not** automatically deployed. The operational engine generates from the freshest observations when the administrator activates a batch. Once committed, the exact generated locations are frozen in a private batch record and are not regenerated.

## Files

- `index.html`: admin-link only; participant UI and submission workflow otherwise unchanged
- `admin-adaptive.html`: administrator status and 20/40 activation controls
- `supabase/functions/liminal-auto-activate/index.ts`: private Edge Function, JWT and administrator checks, generation, retry check
- `supabase/functions/_shared/adaptive-engine.mjs`: shared adaptive selection engine (not the personal hotspot engine)
- `research/drafts/auto-activation.DO-NOT-RUN.sql`: new private batch table, admin status RPC, atomic server-only commit RPC
- `research/tests/auto-activation-smoke.sql`: disposable-PostgreSQL tests
- `research/admin-ui-contract.test.js`: participant UI and administrator-only integration checks
- `research/edge-engine-parity.test.mjs`: selected-site generator parity and 20/40 mix tests

## Tests already available on the development branch

1. Pure JavaScript synthetic sampling tests, including parity of the private Edge engine with the studied shared engine.
2. Deno type check of the Edge Function (no Supabase keys).
3. Disposable PostgreSQL tests for administrator authentication, service-only coordinates commit, initial 20 and later 40 pair activation, expected phase percentages, sequential assignments, idempotence and preservation of original responses and assignments.
4. Static administrator page tests and checks that participant collection functions are not replaced.

**These do not constitute a full Supabase integration test.**

## Mandatory next verification — isolated Supabase staging

- Create a completely separate Supabase project. Do not clone production data, auth accounts, assignments, participant emails, or secrets.
- Apply a fresh copy of the relevant study schema, existing live collection API, then the proposed adaptive draft **to staging only**.
- Use two synthetic test identities (one designated admin). Insert 100 synthetic matched pairs and mock responses through controlled fixtures.
- Deploy the Edge Function only to staging, with staging-specific keys. Verify administrator status is denied to non-admin, public/anonymous clients cannot read responses, and both participant apps remain blinded.
- Verify 20 and 40 actions end-to-end through the real browser and Supabase client, including role claims, CORS, `auth.role()`, and response/assignment counts.
- Simulate network timeouts, concurrent requests, duplicate request IDs and refreshed admin sessions. Confirm no double append.
- Verify the original 200 assignment records and 200 synthetic responses are **byte-for-byte unchanged**, including order, identifiers and notes.
- Confirm each user's locations follow independent orders and a user cannot retrieve a matched partner's coordinates or the other person's answers.
- Test final participant UI visually and behaviorally, including the daily limit and session login/logout. The administrator link must never appear for the non-admin.
- Verify all new objects have RLS and no browser table grants, and the commit RPC is executable by `service_role` **only**.
- Rehearse rollback in staging. The live study must never be rolled back by deleting original records.

## Production gate — requires separate owner approval

1. Validate a fresh read-only production permissions inventory. Obtain and verify a fresh database backup, including participant comments and existing responses.
2. Pause while assessing the latest development and deployed versions to ensure no unrelated participant UI change is being merged.
3. Apply only the reviewed additive migration and Edge Function, then the reviewed admin-only app update, after explicit go-ahead.
4. Test administrator status before any activation. Record production counts and hashes before and after.
5. **Do not activate any new locations automatically during deployment.** The administrator must deliberately choose 20 or 40 after both participants finish the currently assigned locations.
6. Never reveal hidden participant responses, comments or partner locations before the planned study conclusion.

## Privacy and failure behavior

- All test fixtures on GitHub must be synthetic. Never upload `snapshot.csv`, `preview.json`, generated coordinates, real response intensities or live service-role credentials.
- Activation uses a UUID request ID to support idempotent retries; the administrator page retains only the pending request ID and count in browser session storage.
- The browser cannot submit location coordinates. The private commit RPC is callable only by `service_role` and checks the verified user's administrator membership.
- The database checks the latest assignment/response counts again in the same transaction as insertion. If they changed during generation, the operation fails without partial assignment insertion.
