-- LIMINALCREEK - ADVANCE SYNTHETIC STAGING RESPONSES ONLY
-- TARGET STAGING PROJECT: mrelwvpixalfycfdarjf
-- DO NOT RUN IN THE LIVE LIMINALCREEK SUPABASE PROJECT.
--
-- Preconditions:
--   - two synthetic Auth accounts (staging-admin@example.invalid and
--     staging-participant@example.invalid)
--   - exactly 100 original matched pairs, plus the first 20 automatic pairs
--   - 88/120 responses for the test administrator and 100/120 for the other
--   - exactly one adaptive batch: locations 101-120, 20 pairs, 50% adaptive
-- This INSERTS only 47 fictional responses: +28 for the administrator
-- (locations 89-116) and +19 for the other participant (101-119).
-- It does NOT modify any assignment, batch, user, or existing response.
-- If any guard fails, the entire transaction is rolled back.

BEGIN;

DO $stage_advance$
DECLARE
 v_sid uuid;
 v_admin uuid;
 v_other uuid;
 v_existing_batch record;
 v_before_a integer;
 v_before_b integer;
 v_inserted integer;
BEGIN
 -- Resolve staging identities by their deliberately undeliverable emails.
 SELECT id INTO STRICT v_admin FROM auth.users
 WHERE email='staging-admin@example.invalid';
 SELECT id INTO STRICT v_other FROM auth.users
 WHERE email='staging-participant@example.invalid';
 IF v_admin=v_other THEN
  RAISE EXCEPTION 'STOP: Both synthetic identities must be distinct';
 END IF;

 -- Fail closed if this is not exactly the one synthetic staging study.
 IF (SELECT count(*) FROM public.studies)<>1 THEN
  RAISE EXCEPTION 'STOP: Expected exactly one staging study';
 END IF;
 SELECT id INTO STRICT v_sid FROM public.studies
 WHERE name='SYNTHETIC staging shared study - not real observations'
   AND started_at IS NOT NULL AND revealed_at IS NULL;
 IF (SELECT count(*) FROM public.participants)<>2
 OR (SELECT count(*) FROM public.participants
      WHERE study_id=v_sid AND user_id=v_admin AND is_admin)<>1
 OR (SELECT count(*) FROM public.participants
      WHERE study_id=v_sid AND user_id=v_other AND NOT is_admin)<>1 THEN
  RAISE EXCEPTION 'STOP: Synthetic participants are missing or differ';
 END IF;

 IF (SELECT count(*) FROM public.assignments)<>240
 OR (SELECT count(*) FROM public.assignments WHERE study_id=v_sid AND user_id=v_admin)<>120
 OR (SELECT count(*) FROM public.assignments WHERE study_id=v_sid AND user_id=v_other)<>120
 OR (SELECT count(DISTINCT pair_id) FROM public.assignments WHERE study_id=v_sid)<>120 THEN
  RAISE EXCEPTION 'STOP: Expected the original 100 plus 20 synthetic matched pairs';
 END IF;

 IF (SELECT count(*) FROM public.liminal_auto_batches)<>1 THEN
  RAISE EXCEPTION 'STOP: Expected exactly one staging adaptive batch';
 END IF;
 SELECT first_sequence,pair_count,adaptive_percent,source_response_count
 INTO STRICT v_existing_batch
 FROM public.liminal_auto_batches WHERE study_id=v_sid;
 IF v_existing_batch.first_sequence<>101
 OR v_existing_batch.pair_count<>20
 OR v_existing_batch.adaptive_percent<>50
 OR v_existing_batch.source_response_count<>188 THEN
  RAISE EXCEPTION 'STOP: The existing batch does not match the planned staging test';
 END IF;

 SELECT count(*) INTO v_before_a FROM public.responses
 WHERE study_id=v_sid AND user_id=v_admin;
 SELECT count(*) INTO v_before_b FROM public.responses
 WHERE study_id=v_sid AND user_id=v_other;

 IF (SELECT count(*) FROM public.responses)<>188
 OR v_before_a<>88 OR v_before_b<>100
 OR (SELECT count(*) FROM public.responses r
    JOIN public.assignments a ON a.id=r.assignment_id
    WHERE r.study_id=v_sid AND a.user_id=v_admin AND a.sequence_no BETWEEN 1 AND 88)<>88
 OR (SELECT count(*) FROM public.responses r
    JOIN public.assignments a ON a.id=r.assignment_id
    WHERE r.study_id=v_sid AND a.user_id=v_other AND a.sequence_no BETWEEN 1 AND 100)<>100
 OR EXISTS (
   SELECT 1 FROM public.responses r WHERE r.study_id=v_sid
   AND r.note IS DISTINCT FROM 'SYNTHETIC TEST OBSERVATION - NOT REAL PARTICIPANT DATA'
 ) THEN
  RAISE EXCEPTION 'STOP: Existing responses are not exactly the expected 188 synthetic observations';
 END IF;

 -- Add responses for all currently unanswered locations through 116/119.
 -- No new candidate generation or assignment changes occur here.
 INSERT INTO public.responses
  (assignment_id,study_id,user_id,valence,descriptions,strength,note,recorded_at)
 SELECT a.id,a.study_id,a.user_id,
  CASE WHEN a.sequence_no%13=0 THEN 'mixed' ELSE 'neutral' END,
  CASE WHEN a.sequence_no%13=0
   THEN ARRAY['synthetic strong impression']
   ELSE ARRAY['synthetic neutral impression'] END,
  CASE WHEN a.sequence_no%13=0 THEN 4::smallint ELSE NULL::smallint END,
  'SYNTHETIC TEST OBSERVATION - NOT REAL PARTICIPANT DATA',
  timestamptz '2026-01-10 09:00:00+00'
 FROM public.assignments a
 WHERE a.study_id=v_sid
   AND ((a.user_id=v_admin AND a.sequence_no BETWEEN 89 AND 116)
     OR (a.user_id=v_other AND a.sequence_no BETWEEN 101 AND 119))
   AND NOT EXISTS (SELECT 1 FROM public.responses r WHERE r.assignment_id=a.id);
 GET DIAGNOSTICS v_inserted = ROW_COUNT;
 IF v_inserted<>47 THEN
  RAISE EXCEPTION 'STOP: Expected 47 inserted synthetic responses; found %',v_inserted;
 END IF;

 -- Postcondition: 116+119=235 responses, no changes to 240 assignments.
 IF (SELECT count(*) FROM public.responses)<>235
 OR (SELECT count(*) FROM public.responses WHERE study_id=v_sid AND user_id=v_admin)<>116
 OR (SELECT count(*) FROM public.responses WHERE study_id=v_sid AND user_id=v_other)<>119
 OR (SELECT count(*) FROM public.assignments)<>240
 OR (SELECT count(*) FROM public.liminal_auto_batches)<>1 THEN
  RAISE EXCEPTION 'STOP: Unexpected post-insertion totals';
 END IF;
 RAISE NOTICE 'STAGING SUCCESS: 47 synthetic responses added; now 116/120 and 119/120 (235 total)';
END
$stage_advance$;

COMMIT;

-- Read-only verification results (two participant rows).
SELECT
 CASE WHEN p.is_admin THEN 'You (synthetic admin)'
      ELSE 'Other synthetic participant' END AS participant,
 (SELECT count(*) FROM public.responses r
    WHERE r.study_id=p.study_id AND r.user_id=p.user_id)::integer AS completed,
 (SELECT count(*) FROM public.assignments a
    WHERE a.study_id=p.study_id AND a.user_id=p.user_id)::integer AS assigned,
 (SELECT count(*) FROM public.responses r
    JOIN public.assignments a ON a.id=r.assignment_id
    WHERE r.study_id=p.study_id AND r.user_id=p.user_id
      AND a.sequence_no BETWEEN 101 AND 120)::integer AS current_set_completed,
 (SELECT count(*) FROM public.responses r WHERE r.study_id=p.study_id)::integer AS total_responses,
 (SELECT count(*) FROM public.liminal_auto_batches b
    WHERE b.study_id=p.study_id)::integer AS batches
FROM public.participants p
JOIN public.studies s ON s.id=p.study_id
WHERE s.name='SYNTHETIC staging shared study - not real observations'
ORDER BY p.is_admin DESC;
