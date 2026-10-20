# LiminalCreek backend (foundation)

The public GitHub Pages app is currently a **local-only prototype**. Its browser data are **not shared** and must not be used as the real blinded study.

The `schema.sql` file creates the first secure Supabase database structure:

- Authenticated study members can see only their own participant record and their own coordinate assignments.
- The paired assignment is keyed internally by `pair_id`, which is not exposed as a second coordinate.
- No client can read responses, including their own, during collection.
- `submit_impression` runs server-side checks for membership, assignment ownership, response schema, order, daily cap, and duplicates.
- Only a trusted administrative environment can create study memberships and assignments or activate reveal.

## Before running the real study
1. Create a Supabase project and enable email authentication.
2. Apply `schema.sql` in its SQL editor, verifying its policies in the Supabase security advisor.
3. Invite the two users, and seed the study/polygon geometry and *individually addressable* paired assignment rows with a trusted server utility.
4. Implement client login, server-backed assignment retrieval and response submission (the static app is not yet wired to this backend).
5. Design the adaptive sampling scheduler, two-person reveal consent, and read-only reveal RPC before real collection.
6. Review rate limits and policies and test that a participant cannot see another participant's coordinates or any response.

**Privacy:** Do not commit private response exports, secrets, service-role tokens, email addresses, or a Supabase service role key. The polygon export is retained with the owner until the private database is provisioned.
