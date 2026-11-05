# Disposable Supabase staging (NOT production)

This directory contains a reproducible integration rehearsal for the **shared** LiminalCreek study.

## What it does
- Uses a **local, unlinked** Supabase project on a disposable GitHub Actions runner.
- Starts genuine Supabase Auth, database, REST API, and Edge Functions.
- Creates only **synthetic** user identities, eligible polygon, 100 initial matched pairs and test observations.
- Applies the saved study schema, current live collection API and **development-only adaptive migration** to the local database.
- Signs in with a normal participant JWT and verifies a separate non-administrator cannot invoke admin operations.
- Verifies an early 20-pair batch at 88/100 and 100/100, then a 30-pair batch at 116/120 and 119/120.
- Checks idempotent retry, prohibition of stacked unopened batches, preservation of the original assignments, and that the participant-facing next-place RPC still points to unfinished earlier assignments.
- Discards the entire local Supabase project at the end.

## How to observe the result
Review the **Disposable Supabase staging integration** workflow on the `shared-adaptive-integration-20261102` branch. All credentials are generated locally and only exist inside the disposable runner.

No hosted Supabase account is created, no project is linked, and no public page is deployed by this workflow. It requires **no production credentials** and makes **no calls to production**.

## Next phase after this passes
If browser testing is needed, prepare a **separate hosted Supabase staging project** using synthetic users and data, not the production dataset or service keys. The project owner should create the hosted staging project in the Supabase dashboard; separate credentials and approval are required before pointing the development administrator page at it.

The live study, assignments, responses, participant app and production configurations **must remain untouched** throughout development.
