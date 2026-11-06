-- LIMINALCREEK PRODUCTION MIGRATION CANDIDATE -- REVIEW ONLY
-- TARGET LIVE BACKEND: fwdsoluixqeycapncecl.supabase.co
-- NEVER run this in staging project mrelwvpixalfycfdarjf.
-- This is NOT authorized for execution yet. Keep the live study untouched.
-- Adds the private batch table and 3 new RPCs only. Does not overwrite the
-- participant next-place or submit-impression APIs, or any existing rows.
-- This script refuses to run unless the expected initial shared-study
-- inventory is intact and no previous adaptive migration has been applied.
-- Before application: verify fresh full backup and a second independent
-- database inventory. Run only after explicit release approval.
BEGIN;

DO $production_release_guard$
DECLARE live_sid uuid;
BEGIN
 IF (SELECT count(*) FROM public.studies
     WHERE started_at IS NOT NULL AND revealed_at IS NULL)<>1
 THEN RAISE EXCEPTION 'STOP: Exactly one active unrevealed study required'; END IF;
 SELECT id INTO live_sid FROM public.studies
 WHERE started_at IS NOT NULL AND revealed_at IS NULL;
 IF (SELECT count(*) FROM public.participants p WHERE p.study_id=live_sid)<>2
 OR (SELECT count(*) FROM public.participants p
     WHERE p.study_id=live_sid AND p.is_admin)=0
 THEN RAISE EXCEPTION 'STOP: Live participant/administrator roster differs'; END IF;
 IF (SELECT count(*) FROM public.assignments a WHERE a.study_id=live_sid)<>200
 OR (SELECT count(DISTINCT a.pair_id) FROM public.assignments a
     WHERE a.study_id=live_sid)<>100
 OR EXISTS (
   SELECT 1 FROM public.participants p
   WHERE p.study_id=live_sid AND
   (SELECT count(*) FROM public.assignments a
    WHERE a.study_id=live_sid AND a.user_id=p.user_id)<>100
 )
 THEN RAISE EXCEPTION 'STOP: Original 200 assignments do not match expected baseline'; END IF;
 IF (SELECT count(*) FROM public.responses r WHERE r.study_id=live_sid)>200
 OR EXISTS (
   SELECT 1 FROM public.responses r
   LEFT JOIN public.assignments a ON a.id=r.assignment_id
   WHERE r.study_id=live_sid AND
   (a.id IS NULL OR a.user_id<>r.user_id OR a.study_id<>r.study_id)
 ) THEN RAISE EXCEPTION 'STOP: Response inventory invalid'; END IF;
 IF EXISTS(SELECT 1 FROM public.assignments a
   WHERE a.study_id=live_sid
   GROUP BY a.user_id,a.sequence_no HAVING count(*)<>1)
 THEN RAISE EXCEPTION 'STOP: Duplicate participant sequence numbers'; END IF;
 IF to_regclass('public.liminal_auto_batches') IS NOT NULL
 OR to_regprocedure('public.liminal_admin_auto_status()') IS NOT NULL
 OR to_regprocedure('public.liminal_my_progress()') IS NOT NULL
 THEN RAISE EXCEPTION 'STOP: Adaptive migration already exists; reconcile before retry'; END IF;
 IF (SELECT polygons->>'type' FROM public.studies WHERE id=live_sid)
    NOT IN ('FeatureCollection','Feature','Polygon','MultiPolygon')
 THEN RAISE EXCEPTION 'STOP: Unsupported active study polygon geometry'; END IF;
END
$production_release_guard$;

-- ===== New private batch table and administrator RPCs =====
CREATE TABLE IF NOT EXISTS public.liminal_auto_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  study_id uuid NOT NULL REFERENCES public.studies(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  first_sequence integer NOT NULL CHECK (first_sequence >= 101),
  pair_count integer NOT NULL CHECK (pair_count BETWEEN 10 AND 40 AND pair_count%10=0),
  source_response_count integer NOT NULL CHECK (source_response_count >= 0),
  adaptive_percent smallint NOT NULL CHECK (adaptive_percent IN (50,75)),
  algorithm_version text NOT NULL DEFAULT 'shared-adaptive-v2',
  seed text NOT NULL,
  frozen_pairs jsonb NOT NULL,
  activated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (study_id,first_sequence),
  CHECK (jsonb_typeof(frozen_pairs)='array'),
  CHECK (jsonb_array_length(frozen_pairs)=pair_count)
);
ALTER TABLE public.liminal_auto_batches ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.liminal_auto_batches FROM PUBLIC,anon,authenticated;
-- No direct table policies: only audited SECURITY DEFINER functions can act.

CREATE OR REPLACE FUNCTION public.liminal_admin_auto_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; members uuid[]; assigned_total bigint; responded_total bigint;
        assigned_a integer; assigned_b integer; completed_a integer; completed_b integer;
        baseline_assigned boolean; queue_consistent boolean; unopened_batch boolean;
        last_batch_start integer; next_seq integer;
BEGIN
 SELECT p.study_id INTO sid FROM public.participants p
 JOIN public.studies s ON s.id=p.study_id
 WHERE p.user_id=auth.uid() AND p.is_admin
   AND s.started_at IS NOT NULL AND s.revealed_at IS NULL
 ORDER BY s.created_at LIMIT 1;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator role required'; END IF;
 SELECT array_agg(p.user_id ORDER BY p.user_id) INTO members
 FROM public.participants p WHERE p.study_id=sid;
 IF coalesce(array_length(members,1),0)<>2 THEN RAISE EXCEPTION 'Exactly two members required'; END IF;
 SELECT count(*) INTO assigned_total FROM public.assignments a WHERE a.study_id=sid;
 SELECT count(*) INTO responded_total FROM public.responses r WHERE r.study_id=sid;
 SELECT count(*) INTO assigned_a FROM public.assignments a WHERE a.study_id=sid AND a.user_id=members[1];
 SELECT count(*) INTO assigned_b FROM public.assignments a WHERE a.study_id=sid AND a.user_id=members[2];
 SELECT count(*) INTO completed_a FROM public.responses r WHERE r.study_id=sid AND r.user_id=members[1];
 SELECT count(*) INTO completed_b FROM public.responses r WHERE r.study_id=sid AND r.user_id=members[2];
 baseline_assigned := NOT EXISTS (
  SELECT 1 FROM unnest(members) AS uid
  WHERE (SELECT count(*) FROM public.assignments a
    WHERE a.study_id=sid AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
 );
 queue_consistent := assigned_a=assigned_b AND assigned_total=2*assigned_a
  AND assigned_a>=100 AND responded_total=completed_a+completed_b
  AND completed_a<=assigned_a AND completed_b<=assigned_b
  AND (SELECT count(DISTINCT a.pair_id) FROM public.assignments a WHERE a.study_id=sid)=assigned_a;
 next_seq:=assigned_a+1;
 SELECT max(b.first_sequence) INTO last_batch_start
 FROM public.liminal_auto_batches b WHERE b.study_id=sid;
 -- Allow one future, not-yet-started batch. New batches may be queued
 -- as soon as either participant begins the latest appended batch.
 unopened_batch:=last_batch_start IS NOT NULL
               AND greatest(completed_a,completed_b)<last_batch_start;
 RETURN jsonb_build_object(
  'studyId',sid,'baselineAssigned',baseline_assigned,
  'queuesConsistent',queue_consistent,'unstartedBatchQueued',unopened_batch,
  'canActivate',baseline_assigned AND queue_consistent AND NOT unopened_batch,
  'assignedRows',assigned_total,'responseRows',responded_total,
  'nextSequence',next_seq,'additionalPairs',greatest(0,next_seq-101),
  'recommendedAdaptivePercent',CASE WHEN next_seq<=140 THEN 50 ELSE 75 END,
  'participants',(
    SELECT jsonb_agg(jsonb_build_object(
      'role',CASE WHEN p.user_id=members[1] THEN 'A' ELSE 'B' END,
      'isYou',p.user_id=auth.uid(),
      'assigned',pr.assigned,'completed',pr.completed,
      'originalCompleted',(SELECT count(*) FROM public.responses r
         JOIN public.assignments a ON a.id=r.assignment_id
         WHERE a.study_id=sid AND r.user_id=p.user_id AND a.sequence_no<=100),
      'currentSetStart',coalesce(active_set.first_sequence,1),
      'currentSetSize',coalesce(active_set.pair_count,100),
      'currentSetCompleted',least(coalesce(active_set.pair_count,100),
         greatest(0,pr.completed-coalesce(active_set.first_sequence,1)+1))
    ) ORDER BY p.user_id)
    FROM public.participants p
    CROSS JOIN LATERAL (
      SELECT
       (SELECT count(*) FROM public.assignments a
         WHERE a.study_id=sid AND a.user_id=p.user_id) AS assigned,
       (SELECT count(*) FROM public.responses r
         WHERE r.study_id=sid AND r.user_id=p.user_id) AS completed
    ) pr
    LEFT JOIN LATERAL (
      SELECT b.first_sequence,b.pair_count FROM public.liminal_auto_batches b
      WHERE b.study_id=sid AND b.first_sequence<=pr.completed+1
      ORDER BY b.first_sequence DESC LIMIT 1
    ) active_set ON TRUE
    WHERE p.study_id=sid
  ),
  'releasedBatches',(SELECT count(*) FROM public.liminal_auto_batches b WHERE b.study_id=sid)
 );
END $$;
REVOKE ALL ON FUNCTION public.liminal_admin_auto_status() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.liminal_admin_auto_status() TO authenticated;

-- Only the trusted Edge Function (service_role) may call this RPC with coordinates.
-- The Edge Function authenticates a real user JWT and supplies the verified actor UUID.
-- The user's browser cannot call this function, even if signed in as administrator.
-- Every insert + the immutable batch record occur in ONE DB transaction.
CREATE OR REPLACE FUNCTION public.liminal_admin_commit_auto_batch(
  p_actor_user_id uuid,
  p_request_id uuid,
  p_expected_assignment_rows integer,
  p_expected_response_rows integer,
  p_seed text,
  p_adaptive_percent smallint,
  p_pairs jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; members uuid[]; rows_current bigint; responses_current bigint;
        original_ready boolean; pair_count integer; start_seq integer;
        idx integer; v_a uuid; v_b uuid; v_batch_id uuid;
        v_mode text; v_pair uuid; v_lona double precision; v_lata double precision;
        v_lonb double precision; v_latb double precision; v_ordera integer;
        v_orderb integer; v_percent integer; v_dist double precision;
        v_row jsonb; last_batch_start integer; most_completed integer;
        broad_count integer; expected_broad double precision;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'Trusted server coordinator required'; END IF;
 IF p_actor_user_id IS NULL THEN RAISE EXCEPTION 'Verified administrator ID required'; END IF;
 IF p_request_id IS NULL OR p_seed IS NULL OR length(p_seed)<12
 OR p_adaptive_percent NOT IN (50,75) OR p_adaptive_percent IS NULL THEN
  RAISE EXCEPTION 'Invalid activation request';
 END IF;
 SELECT p.study_id INTO sid FROM public.participants p
 JOIN public.studies s ON s.id=p.study_id
 WHERE p.user_id=p_actor_user_id AND p.is_admin
   AND s.started_at IS NOT NULL AND s.revealed_at IS NULL
 ORDER BY s.created_at LIMIT 1;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator required'; END IF;
 -- Serialize competing activation requests; concurrent requests cannot double-append.
 PERFORM 1 FROM public.studies s WHERE s.id=sid FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.liminal_auto_batches b
           WHERE b.request_id=p_request_id AND b.study_id=sid) THEN
  RETURN (SELECT jsonb_build_object('batchId',b.id,'addedPairs',b.pair_count,
    'firstSequence',b.first_sequence,'alreadyCommitted',true)
    FROM public.liminal_auto_batches b WHERE b.request_id=p_request_id);
 END IF;
 SELECT array_agg(p.user_id ORDER BY p.user_id) INTO members
 FROM public.participants p WHERE p.study_id=sid;
 IF coalesce(array_length(members,1),0)<>2 THEN RAISE EXCEPTION 'Two study members required'; END IF;
 v_a:=members[1]; v_b:=members[2];
 SELECT count(*) INTO rows_current FROM public.assignments a WHERE a.study_id=sid;
 SELECT count(*) INTO responses_current FROM public.responses r WHERE r.study_id=sid;
 IF rows_current<>p_expected_assignment_rows OR responses_current<>p_expected_response_rows THEN
  RAISE EXCEPTION 'Study changed since sampling snapshot; retry activation';
 END IF;
 IF rows_current<200 OR mod(rows_current,2)<>0 OR responses_current>rows_current THEN
  RAISE EXCEPTION 'Invalid study assignment/response inventory';
 END IF;
 start_seq:=rows_current/2+1;
 -- Do not stack multiple batches ahead: one unopened batch is sufficient
 -- to avoid a gap when participants reach the end of the current set.
 SELECT max(b.first_sequence) INTO last_batch_start
 FROM public.liminal_auto_batches b WHERE b.study_id=sid;
 SELECT greatest(
   (SELECT count(*) FROM public.responses r WHERE r.study_id=sid AND r.user_id=v_a),
   (SELECT count(*) FROM public.responses r WHERE r.study_id=sid AND r.user_id=v_b)
 ) INTO most_completed;
 IF last_batch_start IS NOT NULL AND most_completed<last_batch_start THEN
  RAISE EXCEPTION 'An upcoming batch is already queued';
 END IF;
 IF (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_a)<>start_seq-1
 OR (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_b)<>start_seq-1
 OR (SELECT count(DISTINCT a.pair_id) FROM public.assignments a
     WHERE a.study_id=sid AND a.sequence_no<=100)<>100
 THEN RAISE EXCEPTION 'Existing matched assignment inventory is inconsistent'; END IF;
 IF EXISTS (
   SELECT 1 FROM unnest(members) AS uid
   WHERE (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid
          AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
 ) THEN RAISE EXCEPTION 'Original assignment inventory must contain 100 per participant'; END IF;
 IF jsonb_typeof(p_pairs)<>'array' THEN RAISE EXCEPTION 'Pair manifest must be an array'; END IF;
 pair_count:=jsonb_array_length(p_pairs);
 IF pair_count NOT IN (10,20,30,40) THEN RAISE EXCEPTION 'Choose 10, 20, 30 or 40 matched pairs'; END IF;
 -- Require the selected mix approximately (mode-count rounding may differ by one).
 SELECT count(*) INTO broad_count FROM jsonb_array_elements(p_pairs) x
 WHERE x->>'mode'='broad';
 expected_broad := pair_count*(100-p_adaptive_percent)/100.0;
 IF abs(broad_count-expected_broad)>1 THEN
  RAISE EXCEPTION 'Sampling mixture does not match selected preset';
 END IF;
 -- Distinct pair IDs and independent, complete sequence permutations.
 IF (SELECT count(DISTINCT (x->>'pairId')) FROM jsonb_array_elements(p_pairs) x)<>pair_count OR
    (SELECT count(DISTINCT (x->>'orderA')::integer) FROM jsonb_array_elements(p_pairs) x)<>pair_count OR
    (SELECT count(DISTINCT (x->>'orderB')::integer) FROM jsonb_array_elements(p_pairs) x)<>pair_count
 THEN RAISE EXCEPTION 'Duplicate pair identifiers or sequence values'; END IF;
 IF EXISTS (
   SELECT 1 FROM jsonb_array_elements(p_pairs) x
   WHERE (x->>'orderA')::integer NOT BETWEEN 1 AND pair_count
      OR (x->>'orderB')::integer NOT BETWEEN 1 AND pair_count
 ) THEN RAISE EXCEPTION 'Invalid independent presentation orders'; END IF;
 -- Both 20-pair groups of the first 40 use 50% adaptive; later groups 75%.
 FOR idx IN 0..pair_count-1 LOOP
  v_row:=p_pairs->idx;
  v_pair:=(v_row->>'pairId')::uuid;
  v_mode:=v_row->>'mode';
  v_lona:=(v_row->>'longitudeA')::double precision;
  v_lata:=(v_row->>'latitudeA')::double precision;
  v_lonb:=(v_row->>'longitudeB')::double precision;
  v_latb:=(v_row->>'latitudeB')::double precision;
  v_ordera:=(v_row->>'orderA')::integer;
  v_orderb:=(v_row->>'orderB')::integer;
  v_percent:=(v_row->>'adaptivePercent')::integer;
  IF v_mode IS NULL OR v_mode NOT IN ('interesting','uncertain','quiet','broad')
    OR v_lona IS NULL OR v_lonb IS NULL OR v_lata IS NULL OR v_latb IS NULL
    OR v_ordera IS NULL OR v_orderb IS NULL OR v_pair IS NULL
    OR v_lona NOT BETWEEN -180 AND 180 OR v_lonb NOT BETWEEN -180 AND 180
    OR v_lata NOT BETWEEN -90 AND 90 OR v_latb NOT BETWEEN -90 AND 90
    OR v_percent IS NULL OR v_percent<>p_adaptive_percent
  THEN RAISE EXCEPTION 'Candidate validation failed'; END IF;
  v_dist:=6371008.8 * sqrt(
    power((v_lonb-v_lona)*pi()/180*cos((v_lata+v_latb)*pi()/360),2)
    +power((v_latb-v_lata)*pi()/180,2));
  IF v_dist IS NULL OR v_dist>60.97 OR v_dist<0.01 THEN RAISE EXCEPTION 'Pair separation outside permitted range'; END IF;
  IF EXISTS(SELECT 1 FROM public.assignments a WHERE a.pair_id=v_pair) THEN
   RAISE EXCEPTION 'Pair was already assigned'; END IF;
 END LOOP;
 INSERT INTO public.liminal_auto_batches
  (study_id,request_id,first_sequence,pair_count,source_response_count,adaptive_percent,seed,frozen_pairs)
 VALUES(sid,p_request_id,start_seq,pair_count,responses_current,p_adaptive_percent,p_seed,p_pairs)
 RETURNING id INTO v_batch_id;
 -- Both insertions are part of the same DB transaction as the frozen manifest.
 INSERT INTO public.assignments
  (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,v_a,(x->>'pairId')::uuid,(x->>'longitudeA')::double precision,
        (x->>'latitudeA')::double precision,
        start_seq+(x->>'orderA')::integer-1,
        CASE WHEN x->>'mode'='broad' THEN 'broad' ELSE 'adaptive' END
 FROM jsonb_array_elements(p_pairs) x;
 INSERT INTO public.assignments
  (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,v_b,(x->>'pairId')::uuid,(x->>'longitudeB')::double precision,
        (x->>'latitudeB')::double precision,
        start_seq+(x->>'orderB')::integer-1,
        CASE WHEN x->>'mode'='broad' THEN 'broad' ELSE 'adaptive' END
 FROM jsonb_array_elements(p_pairs) x;
 RETURN jsonb_build_object('batchId',v_batch_id,'addedPairs',pair_count,
   'firstSequence',start_seq,'alreadyCommitted',false);
END $$;
REVOKE ALL ON FUNCTION public.liminal_admin_commit_auto_batch(uuid,uuid,integer,integer,text,smallint,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.liminal_admin_commit_auto_batch(uuid,uuid,integer,integer,text,smallint,jsonb) TO service_role;

-- Always run permission audits again after any eventual deployment.

-- ===== New signed-in participant's own progress RPC =====
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

-- Validate table access and routine privileges outside this transaction.
COMMIT;

-- Read-only postflight, run separately and review:
-- SELECT count(*) FROM public.liminal_auto_batches;
-- SELECT has_function_privilege('authenticated',
--   'public.liminal_admin_commit_auto_batch(uuid,uuid,integer,integer,text,smallint,jsonb)','EXECUTE');
