-- LiminalCreek participant progress — ADDITIVE staging-only migration
-- Target: mrelwvpixalfycfdarjf (synthetic staging project).
-- NEVER run against the production study without separate release approval.
-- Returns only the signed-in user's counts and current batch boundaries;
-- no peer identities, responses, coordinates, or personal notes are exposed.
-- Does not modify existing study data, assignments, or participant functions.
BEGIN;
CREATE OR REPLACE FUNCTION public.liminal_my_progress()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE
  v_uid uuid:=auth.uid();
  v_sid uuid;
  v_assigned integer;
  v_completed integer;
  v_next_sequence integer;
  v_batch_start integer:=1;
  v_batch_count integer:=100;
  v_batch_completed integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
  SELECT s.id INTO v_sid
  FROM public.studies s
  JOIN public.participants p ON p.study_id=s.id
  WHERE p.user_id=v_uid AND s.started_at IS NOT NULL
    AND s.revealed_at IS NULL
  ORDER BY s.created_at LIMIT 1;
  IF v_sid IS NULL THEN
    RAISE EXCEPTION 'No active study for this account';
  END IF;

  SELECT count(*) INTO v_assigned
  FROM public.assignments a WHERE a.study_id=v_sid AND a.user_id=v_uid;
  SELECT count(*) INTO v_completed
  FROM public.responses r WHERE r.study_id=v_sid AND r.user_id=v_uid;

  SELECT min(a.sequence_no) INTO v_next_sequence
  FROM public.assignments a
  WHERE a.study_id=v_sid AND a.user_id=v_uid
    AND NOT EXISTS(SELECT 1 FROM public.responses r WHERE r.assignment_id=a.id);
  v_next_sequence:=coalesce(v_next_sequence,v_assigned+1);

  SELECT b.first_sequence,b.pair_count INTO v_batch_start,v_batch_count
  FROM public.liminal_auto_batches b
  WHERE b.study_id=v_sid AND b.first_sequence<=v_next_sequence
  ORDER BY b.first_sequence DESC LIMIT 1;
  IF NOT FOUND THEN
    v_batch_start:=1;
    v_batch_count:=100;
  END IF;

  SELECT count(*) INTO v_batch_completed
  FROM public.responses r
  JOIN public.assignments a ON a.id=r.assignment_id
  WHERE a.study_id=v_sid AND a.user_id=v_uid
    AND a.sequence_no BETWEEN v_batch_start AND v_batch_start+v_batch_count-1;

  RETURN jsonb_build_object(
    'assigned',v_assigned,
    'completed',v_completed,
    'remaining',greatest(0,v_assigned-v_completed),
    'currentSetStart',v_batch_start,
    'currentSetSize',v_batch_count,
    'currentSetCompleted',v_batch_completed,
    'nextSequence',v_next_sequence
  );
END $$;

REVOKE ALL ON FUNCTION public.liminal_my_progress() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.liminal_my_progress() TO authenticated;
COMMIT;

-- Read-only verification (permissions only):
SELECT
  has_function_privilege('anon','public.liminal_my_progress()','EXECUTE')
      AS anonymous_can_execute,
  has_function_privilege('authenticated','public.liminal_my_progress()','EXECUTE')
      AS participant_can_execute;
