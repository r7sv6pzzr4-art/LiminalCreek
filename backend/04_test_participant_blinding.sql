-- LiminalCreek pre-activation security test; read-only.
-- Run this WHOLE SCRIPT in Supabase SQL Editor as project owner.
-- It impersonates each already registered UUID only inside two rolled-back transactions.
-- It does not activate the study, alter locations, or write observations.

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','213df724-39d6-4a82-9110-9dbdc67b0e38',true);
SELECT 'participant_A' AS test_identity, auth.uid() AS resolved_uid;
SELECT 'participant_A' AS test_identity, started, assignment_id IS NULL AS location_hidden,
       completed, completed_today FROM public.next_liminal_place();
SELECT 'participant_A' AS test_identity,
       has_table_privilege('authenticated','public.assignments','SELECT') AS can_read_assignment_table,
       has_table_privilege('authenticated','public.responses','SELECT') AS can_read_response_table;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','346ea76f-0cf1-4038-a828-d64952bb9ef9',true);
SELECT 'participant_B' AS test_identity, auth.uid() AS resolved_uid;
SELECT 'participant_B' AS test_identity, started, assignment_id IS NULL AS location_hidden,
       completed, completed_today FROM public.next_liminal_place();
SELECT 'participant_B' AS test_identity,
       has_table_privilege('authenticated','public.assignments','SELECT') AS can_read_assignment_table,
       has_table_privilege('authenticated','public.responses','SELECT') AS can_read_response_table;
ROLLBACK;

-- Expected for A and B:
-- started=false; location_hidden=true; completed=0; completed_today=0;
-- can_read_assignment_table=false; can_read_response_table=false.
