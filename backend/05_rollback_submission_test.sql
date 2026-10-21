-- LiminalCreek end-to-end security and submission test.
-- Run WHOLE script as project owner in Supabase SQL Editor.
-- All changes, including temporary activation and two simulated responses, are ROLLED BACK.
-- Stop and report any ERROR. Do not activate the actual study yet.

BEGIN;
SELECT set_config('liminal.test_a',
 (SELECT id::text FROM public.assignments WHERE user_id='213df724-39d6-4a82-9110-9dbdc67b0e38'
 ORDER BY sequence_no LIMIT 1),true);
SELECT set_config('liminal.test_b',
 (SELECT id::text FROM public.assignments WHERE user_id='346ea76f-0cf1-4038-a828-d64952bb9ef9'
 ORDER BY sequence_no LIMIT 1),true);

SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','213df724-39d6-4a82-9110-9dbdc67b0e38',true);
DO $$
DECLARE rejected boolean:=false; row_data record;
BEGIN
 SELECT * INTO row_data FROM public.next_liminal_place();
 IF row_data.started IS DISTINCT FROM false OR row_data.assignment_id IS NOT NULL THEN
  RAISE EXCEPTION 'FAIL: pre-start location was exposed';
 END IF;
 BEGIN
  PERFORM public.submit_impression(
   current_setting('liminal.test_a')::uuid,'neutral',
   ARRAY['I have no particular feelings about this place'],NULL::smallint,'rollback-only test');
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%not started%' THEN rejected:=true;
  ELSE RAISE; END IF;
 END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL: response was allowed before activation'; END IF;
 RAISE NOTICE 'PASS: location hidden and submission rejected before activation';
END $$;

RESET ROLE;
UPDATE public.studies SET started_at=now()
WHERE id='664b110e-7d5e-445e-815c-986430baf9bd' AND started_at IS NULL;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','213df724-39d6-4a82-9110-9dbdc67b0e38',true);
DO $$
DECLARE row_data record; rejected boolean:=false;
BEGIN
 SELECT * INTO row_data FROM public.next_liminal_place();
 IF row_data.assignment_id IS DISTINCT FROM current_setting('liminal.test_a')::uuid THEN
  RAISE EXCEPTION 'FAIL: A did not receive their own first assignment';
 END IF;
 BEGIN
  PERFORM public.submit_impression(current_setting('liminal.test_b')::uuid,
   'neutral',ARRAY['I have no particular feelings about this place'],NULL::smallint,'');
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM LIKE '%not found%' THEN rejected:=true;
  ELSE RAISE; END IF;
 END;
 IF NOT rejected THEN RAISE EXCEPTION 'FAIL: A submitted B assignment'; END IF;
 PERFORM public.submit_impression(current_setting('liminal.test_a')::uuid,
  'neutral',ARRAY['I have no particular feelings about this place'],NULL::smallint,'rollback-only A');
 RAISE NOTICE 'PASS: A sees only own first assignment, B access rejected, A submit accepted';
END $$;

SELECT set_config('request.jwt.claim.sub','346ea76f-0cf1-4038-a828-d64952bb9ef9',true);
DO $$
DECLARE row_data record;
BEGIN
 SELECT * INTO row_data FROM public.next_liminal_place();
 IF row_data.assignment_id IS DISTINCT FROM current_setting('liminal.test_b')::uuid THEN
  RAISE EXCEPTION 'FAIL: B did not receive their own first assignment';
 END IF;
 PERFORM public.submit_impression(current_setting('liminal.test_b')::uuid,
  'neutral',ARRAY['I have no particular feelings about this place'],NULL::smallint,'rollback-only B');
 RAISE NOTICE 'PASS: B sees own first assignment and submit accepted';
END $$;

ROLLBACK;

-- These results must remain 0 and false after the rollback.
SELECT
 (SELECT count(*) FROM public.responses WHERE study_id='664b110e-7d5e-445e-815c-986430baf9bd') AS real_responses_after_test,
 (SELECT started_at IS NOT NULL FROM public.studies WHERE id='664b110e-7d5e-445e-815c-986430baf9bd') AS study_started_after_test,
 (SELECT count(*) FROM public.assignments WHERE study_id='664b110e-7d5e-445e-815c-986430baf9bd') AS assignments_preserved;
