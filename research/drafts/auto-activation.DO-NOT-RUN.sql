-- DEVELOPMENT DRAFT ONLY. DO NOT APPLY TO PRODUCTION.
-- Purpose: one authenticated administrator action generates and releases 20/40
-- matched shared-study pairs. No manual pair review or staging step.
-- Run in a disposable Supabase database after schema and existing live API.
-- Never deploy until separate staging verification and explicit owner approval.
-- Participant tables and existing RPCs are NOT altered by this draft.

CREATE TABLE IF NOT EXISTS public.liminal_auto_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  study_id uuid NOT NULL REFERENCES public.studies(id) ON DELETE RESTRICT,
  request_id uuid NOT NULL UNIQUE,
  first_sequence integer NOT NULL CHECK (first_sequence >= 101),
  pair_count integer NOT NULL CHECK (pair_count IN (20,40)),
  source_response_count integer NOT NULL CHECK (source_response_count >= 200),
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
        original_ready boolean; queues_ready boolean; next_seq integer;
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
 original_ready := NOT EXISTS (
  SELECT 1 FROM unnest(members) AS uid
  WHERE (SELECT count(*) FROM public.assignments a
    WHERE a.study_id=sid AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
   OR (SELECT count(*) FROM public.responses r JOIN public.assignments a
      ON a.id=r.assignment_id WHERE a.study_id=sid AND a.user_id=uid
      AND a.sequence_no BETWEEN 1 AND 100)<>100
 );
 queues_ready := assigned_total=responded_total
   AND assigned_total>=200 AND mod(assigned_total,2)=0;
 next_seq := assigned_total/2+1;
 RETURN jsonb_build_object(
  'studyId',sid,'originalReady',original_ready,
  'queuesReady',queues_ready,'canActivate',original_ready AND queues_ready,
  'assignedRows',assigned_total,'responseRows',responded_total,
  'nextSequence',next_seq,
  'additionalPairs',greatest(0,next_seq-101),
  'nextAdaptivePercent',CASE WHEN next_seq<=140 THEN 50 ELSE 75 END,
  'participants',(SELECT jsonb_agg(jsonb_build_object(
    'role',CASE WHEN p.user_id=members[1] THEN 'A' ELSE 'B' END,
    'assigned',(SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=p.user_id),
    'completed',(SELECT count(*) FROM public.responses r WHERE r.study_id=sid AND r.user_id=p.user_id),
    'originalCompleted',(SELECT count(*) FROM public.responses r
       JOIN public.assignments a ON a.id=r.assignment_id
       WHERE r.study_id=sid AND r.user_id=p.user_id AND a.sequence_no<=100)
   ) ORDER BY p.user_id) FROM public.participants p WHERE p.study_id=sid),
  'releasedBatches',(SELECT count(*) FROM public.liminal_auto_batches b WHERE b.study_id=sid)
 );
END $$;
REVOKE ALL ON FUNCTION public.liminal_admin_auto_status() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.liminal_admin_auto_status() TO authenticated;

-- Private Edge Function invokes this RPC *with the administrator's JWT*.
-- Every insert + the immutable batch record occur in ONE DB transaction.
-- The client cannot send candidate coordinates, only a 20/40 count.
CREATE OR REPLACE FUNCTION public.liminal_admin_commit_auto_batch(
  p_request_id uuid,
  p_expected_assignment_rows integer,
  p_expected_response_rows integer,
  p_seed text,
  p_pairs jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; members uuid[]; rows_current bigint; responses_current bigint;
        original_ready boolean; pair_count integer; start_seq integer;
        idx integer; v_a uuid; v_b uuid; v_batch_id uuid;
        v_mode text; v_pair uuid; v_lona double precision; v_lata double precision;
        v_lonb double precision; v_latb double precision; v_ordera integer;
        v_orderb integer; v_percent integer; v_dist double precision;
        v_row jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
 IF p_request_id IS NULL OR p_seed IS NULL OR length(p_seed)<12 THEN
  RAISE EXCEPTION 'Invalid activation request';
 END IF;
 SELECT p.study_id INTO sid FROM public.participants p
 JOIN public.studies s ON s.id=p.study_id
 WHERE p.user_id=auth.uid() AND p.is_admin
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
 IF rows_current<200 OR mod(rows_current,2)<>0 OR rows_current<>responses_current THEN
  RAISE EXCEPTION 'Both participants must finish all currently assigned locations';
 END IF;
 start_seq:=rows_current/2+1;
 IF (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_a)<>start_seq-1
 OR (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_b)<>start_seq-1
 OR (SELECT count(DISTINCT a.pair_id) FROM public.assignments a
     WHERE a.study_id=sid AND a.sequence_no<=100)<>100
 THEN RAISE EXCEPTION 'Existing matched assignment inventory is inconsistent'; END IF;
 IF EXISTS (
   SELECT 1 FROM unnest(members) AS uid
   WHERE (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid
          AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
    OR (SELECT count(*) FROM public.responses r JOIN public.assignments a ON r.assignment_id=a.id
        WHERE a.study_id=sid AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
 ) THEN RAISE EXCEPTION 'Original 100 must be complete for both people'; END IF;
 IF jsonb_typeof(p_pairs)<>'array' THEN RAISE EXCEPTION 'Pair manifest must be an array'; END IF;
 pair_count:=jsonb_array_length(p_pairs);
 IF pair_count NOT IN (20,40) THEN RAISE EXCEPTION 'Choose exactly 20 or 40 matched pairs'; END IF;
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
  IF v_mode NOT IN ('interesting','uncertain','quiet','broad')
    OR v_lona NOT BETWEEN -180 AND 180 OR v_lonb NOT BETWEEN -180 AND 180
    OR v_lata NOT BETWEEN -90 AND 90 OR v_latb NOT BETWEEN -90 AND 90
    OR v_percent<>(CASE WHEN start_seq+idx<=140 THEN 50 ELSE 75 END)
  THEN RAISE EXCEPTION 'Candidate validation failed'; END IF;
  v_dist:=6371008.8 * sqrt(
    power((v_lonb-v_lona)*pi()/180*cos((v_lata+v_latb)*pi()/360),2)
    +power((v_latb-v_lata)*pi()/180,2));
  IF v_dist>60.97 OR v_dist<0.01 THEN RAISE EXCEPTION 'Pair separation outside permitted range'; END IF;
  IF EXISTS(SELECT 1 FROM public.assignments a WHERE a.pair_id=v_pair) THEN
   RAISE EXCEPTION 'Pair was already assigned'; END IF;
 END LOOP;
 INSERT INTO public.liminal_auto_batches
  (study_id,request_id,first_sequence,pair_count,source_response_count,seed,frozen_pairs)
 VALUES(sid,p_request_id,start_seq,pair_count,responses_current,p_seed,p_pairs)
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
REVOKE ALL ON FUNCTION public.liminal_admin_commit_auto_batch(uuid,integer,integer,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.liminal_admin_commit_auto_batch(uuid,integer,integer,text,jsonb) TO authenticated;

-- Always run permission audits again after any eventual deployment.
