-- ONE-TIME PRODUCTION MIGRATION CANDIDATE: FINAL FOCUSED BATCH.
-- REVIEW ONLY. Do NOT apply until a separately approved deployment.
-- Existing assignments and responses are never updated or deleted.
-- Existing adaptive batches retain their settings and continue to work.
BEGIN;
DO $guard$
BEGIN
 IF to_regclass('public.liminal_auto_batches') IS NULL
 OR to_regprocedure('public.liminal_admin_auto_status()') IS NULL
 OR to_regprocedure('public.liminal_admin_commit_auto_batch(uuid,uuid,integer,integer,text,smallint,jsonb)') IS NULL
 THEN RAISE EXCEPTION 'STOP: Existing adaptive deployment is required'; END IF;
 IF EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='liminal_auto_batches'
      AND column_name='batch_kind')
 OR to_regprocedure('public.liminal_admin_commit_focused_batch(uuid,uuid,integer,integer,text,jsonb,jsonb)') IS NOT NULL
 THEN RAISE EXCEPTION 'STOP: Final focused extension already installed'; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_constraint
  WHERE conrelid='public.liminal_auto_batches'::regclass
   AND conname='liminal_auto_batches_adaptive_percent_check')
 THEN RAISE EXCEPTION 'STOP: Existing adaptive-percent constraint differs'; END IF;
END $guard$;

ALTER TABLE public.liminal_auto_batches
  ADD COLUMN batch_kind text NOT NULL DEFAULT 'adaptive',
  ADD COLUMN focus_polygons jsonb;
ALTER TABLE public.liminal_auto_batches
  DROP CONSTRAINT liminal_auto_batches_adaptive_percent_check;
ALTER TABLE public.liminal_auto_batches
  ADD CONSTRAINT liminal_auto_batches_adaptive_percent_check
    CHECK (adaptive_percent IN (0,50,75)),
  ADD CONSTRAINT liminal_focused_kind_check CHECK (
    (batch_kind='adaptive' AND adaptive_percent IN (50,75) AND focus_polygons IS NULL)
    OR (batch_kind='focused_final' AND adaptive_percent=0 AND pair_count=20
      AND focus_polygons IS NOT NULL
      AND jsonb_typeof(focus_polygons)='object')
  );
CREATE UNIQUE INDEX liminal_one_final_batch_per_study
 ON public.liminal_auto_batches(study_id)
 WHERE batch_kind='focused_final';

-- Defense in depth: after a final batch exists, even the privileged
-- existing adaptive insert function cannot append another batch.
CREATE OR REPLACE FUNCTION public.liminal__block_postfinal()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
BEGIN
 IF EXISTS (SELECT 1 FROM public.liminal_auto_batches b
  WHERE b.study_id=NEW.study_id AND b.batch_kind='focused_final')
 THEN RAISE EXCEPTION 'The final focus batch has ended further assignment activation'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.liminal__block_postfinal() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER liminal_no_postfinal_insert
 BEFORE INSERT ON public.liminal_auto_batches
 FOR EACH ROW EXECUTE FUNCTION public.liminal__block_postfinal();

-- The existing administrator status RPC is replaced ONLY to add the
-- permanent final-batch stop flag; its other fields and privacy are unchanged.
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
  'canActivate',baseline_assigned AND queue_consistent AND NOT unopened_batch
    AND NOT EXISTS (SELECT 1 FROM public.liminal_auto_batches b
      WHERE b.study_id=sid AND b.batch_kind='focused_final'),
  'finalFocused',EXISTS (SELECT 1 FROM public.liminal_auto_batches b
      WHERE b.study_id=sid AND b.batch_kind='focused_final'),
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


-- Additional independent SQL containment validation. The Edge Function
-- already checks the same supplied polygons and their intersection with the
-- official eligible area (including exclusion rings).
CREATE OR REPLACE FUNCTION public.liminal__in_ring(
 p_lon double precision,p_lat double precision,p_ring jsonb
) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=''
AS $$
DECLARE i integer; j integer; n integer; ai jsonb; aj jsonb;
        x1 double precision;y1 double precision;x2 double precision;y2 double precision;
        inside boolean:=false;
BEGIN
 IF jsonb_typeof(p_ring)<>'array' THEN RETURN false; END IF;
 n:=jsonb_array_length(p_ring);
 IF n<4 THEN RETURN false; END IF;
 j:=n-1;
 FOR i IN 0..n-1 LOOP
  ai:=p_ring->i; aj:=p_ring->j;
  x1:=(ai->>0)::double precision; y1:=(ai->>1)::double precision;
  x2:=(aj->>0)::double precision; y2:=(aj->>1)::double precision;
  IF (y1>p_lat)<>(y2>p_lat) AND
     p_lon<(x2-x1)*(p_lat-y1)/(y2-y1)+x1
  THEN inside:=NOT inside; END IF;
  j:=i;
 END LOOP;
 RETURN inside;
END $$;
REVOKE ALL ON FUNCTION public.liminal__in_ring(double precision,double precision,jsonb)
 FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.liminal__in_geometry(
 p_lon double precision,p_lat double precision,p_geo jsonb
) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path=''
AS $$
DECLARE feat jsonb; geom jsonb; poly jsonb; ring jsonb;
        areas jsonb; i integer; n integer; hole jsonb; inside boolean;
BEGIN
 IF p_geo->>'type'='FeatureCollection' THEN
  FOR feat IN SELECT value FROM jsonb_array_elements(p_geo->'features') LOOP
   IF public.liminal__in_geometry(p_lon,p_lat,feat->'geometry') THEN RETURN true; END IF;
  END LOOP;
  RETURN false;
 ELSIF p_geo->>'type'='Feature' THEN
  RETURN public.liminal__in_geometry(p_lon,p_lat,p_geo->'geometry');
 ELSIF p_geo->>'type'='Polygon' THEN
  areas:=jsonb_build_array(p_geo->'coordinates');
 ELSIF p_geo->>'type'='MultiPolygon' THEN
  areas:=p_geo->'coordinates';
 ELSE RETURN false;
 END IF;
 FOR poly IN SELECT value FROM jsonb_array_elements(areas) LOOP
  IF jsonb_array_length(poly)<1 THEN CONTINUE; END IF;
  inside:=public.liminal__in_ring(p_lon,p_lat,poly->0);
  IF inside THEN
   FOR i IN 1..jsonb_array_length(poly)-1 LOOP
    IF public.liminal__in_ring(p_lon,p_lat,poly->i) THEN
     inside:=false; EXIT;
    END IF;
   END LOOP;
   IF inside THEN RETURN true; END IF;
  END IF;
 END LOOP;
 RETURN false;
END $$;
REVOKE ALL ON FUNCTION public.liminal__in_geometry(double precision,double precision,jsonb)
 FROM PUBLIC,anon,authenticated;

-- This is a separate service-role-only commit RPC. The existing 50/75%
-- adaptive insert RPC is unchanged, and cannot manufacture a final batch.
CREATE OR REPLACE FUNCTION public.liminal_admin_commit_focused_batch(
 p_actor_user_id uuid, p_request_id uuid,
 p_expected_assignment_rows integer,p_expected_response_rows integer,
 p_seed text,p_focus_polygons jsonb,p_pairs jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; members uuid[]; v_a uuid; v_b uuid;
 rows_current integer;responses_current integer;start_seq integer;
 v_batch_id uuid; most_completed integer; last_batch_start integer;
 official jsonb; pair_count integer; row jsonb; area integer; pair_id uuid;
 lon_a double precision;lat_a double precision;lon_b double precision;lat_b double precision;
 order_a integer;order_b integer; separation double precision;
 prior record; i integer;
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN
  RAISE EXCEPTION 'Trusted server coordinator required'; END IF;
 IF p_actor_user_id IS NULL OR p_request_id IS NULL OR length(coalesce(p_seed,''))<12
 THEN RAISE EXCEPTION 'Invalid final focused request'; END IF;
 SELECT p.study_id INTO sid FROM public.participants p
 JOIN public.studies s ON s.id=p.study_id
 WHERE p.user_id=p_actor_user_id AND p.is_admin
  AND s.started_at IS NOT NULL AND s.revealed_at IS NULL
 ORDER BY s.created_at LIMIT 1;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator role required'; END IF;
 PERFORM 1 FROM public.studies s WHERE s.id=sid FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.liminal_auto_batches b
  WHERE b.study_id=sid AND b.request_id=p_request_id) THEN
  RETURN (SELECT jsonb_build_object('batchId',b.id,'addedPairs',b.pair_count,
   'firstSequence',b.first_sequence,'alreadyCommitted',true)
   FROM public.liminal_auto_batches b
   WHERE b.study_id=sid AND b.request_id=p_request_id);
 END IF;
 IF EXISTS(SELECT 1 FROM public.liminal_auto_batches b
  WHERE b.study_id=sid AND b.batch_kind='focused_final') THEN
  RAISE EXCEPTION 'The final focused batch is already assigned'; END IF;
 SELECT array_agg(p.user_id ORDER BY p.user_id) INTO members
  FROM public.participants p WHERE p.study_id=sid;
 IF coalesce(array_length(members,1),0)<>2 THEN
  RAISE EXCEPTION 'Exactly two study participants required'; END IF;
 v_a:=members[1]; v_b:=members[2];
 SELECT count(*) INTO rows_current FROM public.assignments a WHERE a.study_id=sid;
 SELECT count(*) INTO responses_current FROM public.responses r WHERE r.study_id=sid;
 IF rows_current<>p_expected_assignment_rows OR responses_current<>p_expected_response_rows
  OR rows_current<200 OR mod(rows_current,2)<>0 THEN
  RAISE EXCEPTION 'Study data changed; retry generation'; END IF;
 start_seq:=rows_current/2+1;
 IF (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_a)<>start_seq-1
  OR (SELECT count(*) FROM public.assignments a WHERE a.study_id=sid AND a.user_id=v_b)<>start_seq-1
  OR (SELECT count(DISTINCT a.pair_id) FROM public.assignments a
    WHERE a.study_id=sid AND a.sequence_no<=100)<>100 THEN
  RAISE EXCEPTION 'Existing original or matched assignment counts differ'; END IF;
 SELECT max(b.first_sequence) INTO last_batch_start FROM public.liminal_auto_batches b
  WHERE b.study_id=sid;
 SELECT greatest(
  (SELECT count(*) FROM public.responses r WHERE r.study_id=sid AND r.user_id=v_a),
  (SELECT count(*) FROM public.responses r WHERE r.study_id=sid AND r.user_id=v_b)
 ) INTO most_completed;
 IF last_batch_start IS NOT NULL AND most_completed<last_batch_start THEN
  RAISE EXCEPTION 'An upcoming batch is already queued'; END IF;
 SELECT polygons INTO official FROM public.studies s WHERE s.id=sid;
 IF p_focus_polygons->>'type'<>'FeatureCollection'
  OR jsonb_array_length(p_focus_polygons->'features')<>2 THEN
  RAISE EXCEPTION 'Final mode requires exactly two polygons'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_focus_polygons->'features') f
  WHERE f->'geometry'->>'type'<>'Polygon'
   OR jsonb_array_length(f->'geometry'->'coordinates')<>1) THEN
  RAISE EXCEPTION 'Final focus polygons must be two simple polygons'; END IF;
 IF jsonb_typeof(p_pairs)<>'array' OR jsonb_array_length(p_pairs)<>20 THEN
  RAISE EXCEPTION 'Final focused batch must contain exactly 20 matched pairs'; END IF;
 pair_count:=20;
 IF (SELECT count(DISTINCT x->>'pairId') FROM jsonb_array_elements(p_pairs) x)<>20
  OR (SELECT count(DISTINCT (x->>'orderA')::integer) FROM jsonb_array_elements(p_pairs) x)<>20
  OR (SELECT count(DISTINCT (x->>'orderB')::integer) FROM jsonb_array_elements(p_pairs) x)<>20
  OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_pairs) x
    WHERE (x->>'orderA')::integer NOT BETWEEN 1 AND 20
       OR (x->>'orderB')::integer NOT BETWEEN 1 AND 20)
 THEN RAISE EXCEPTION 'Repeated pair IDs or invalid sequence permutation'; END IF;
 IF (SELECT count(*) FROM jsonb_array_elements(p_pairs) x WHERE (x->>'focusArea')::integer=1)<>10
 OR (SELECT count(*) FROM jsonb_array_elements(p_pairs) x WHERE (x->>'focusArea')::integer=2)<>10
 THEN RAISE EXCEPTION 'Focus allocation must be 10 pairs per polygon'; END IF;
 FOR i IN 0..19 LOOP
  row:=p_pairs->i;
  area:=(row->>'focusArea')::integer;
  pair_id:=(row->>'pairId')::uuid;
  lon_a:=(row->>'longitudeA')::double precision;
  lat_a:=(row->>'latitudeA')::double precision;
  lon_b:=(row->>'longitudeB')::double precision;
  lat_b:=(row->>'latitudeB')::double precision;
  order_a:=(row->>'orderA')::integer;
  order_b:=(row->>'orderB')::integer;
  IF row->>'mode'<>'focused' OR area NOT BETWEEN 1 AND 2
     OR lon_a NOT BETWEEN -180 AND 180 OR lon_b NOT BETWEEN -180 AND 180
     OR lat_a NOT BETWEEN -90 AND 90 OR lat_b NOT BETWEEN -90 AND 90
     OR pair_id IS NULL OR order_a IS NULL OR order_b IS NULL
  THEN RAISE EXCEPTION 'Invalid focused pair fields'; END IF;
  separation:=6371008.8*sqrt(
    power((lon_b-lon_a)*pi()/180*cos((lat_a+lat_b)*pi()/360),2)
   +power((lat_b-lat_a)*pi()/180,2));
  IF separation IS NULL OR separation<2 OR separation>60.96 THEN
   RAISE EXCEPTION 'Pair distance invalid'; END IF;
  IF NOT public.liminal__in_geometry(lon_a,lat_a,official)
    OR NOT public.liminal__in_geometry(lon_b,lat_b,official)
    OR NOT public.liminal__in_geometry(lon_a,lat_a,
      (p_focus_polygons->'features'->(area-1))->'geometry')
    OR NOT public.liminal__in_geometry(lon_b,lat_b,
      (p_focus_polygons->'features'->(area-1))->'geometry')
  THEN RAISE EXCEPTION 'New pair falls outside the focus and eligible study intersection'; END IF;
  -- Reusing an earlier location is prohibited, including both participant sides.
  IF EXISTS (SELECT 1 FROM public.assignments a WHERE a.study_id=sid
    AND 6371008.8*sqrt(
      power((a.longitude-lon_a)*pi()/180*cos((a.latitude+lat_a)*pi()/360),2)
       + power((a.latitude-lat_a)*pi()/180,2))<19.5)
   OR EXISTS(SELECT 1 FROM public.assignments a WHERE a.study_id=sid
    AND 6371008.8*sqrt(
      power((a.longitude-lon_b)*pi()/180*cos((a.latitude+lat_b)*pi()/360),2)
       + power((a.latitude-lat_b)*pi()/180,2))<19.5)
  THEN RAISE EXCEPTION 'A focused site is too near a previous assignment'; END IF;
 END LOOP;
 INSERT INTO public.liminal_auto_batches
   (study_id,request_id,first_sequence,pair_count,source_response_count,
    adaptive_percent,algorithm_version,seed,frozen_pairs,batch_kind,focus_polygons)
 VALUES(sid,p_request_id,start_seq,20,responses_current,
        0,'focused-spaced-v1',p_seed,p_pairs,'focused_final',p_focus_polygons)
 RETURNING id INTO v_batch_id;
 INSERT INTO public.assignments
  (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,v_a,(x->>'pairId')::uuid,(x->>'longitudeA')::double precision,
  (x->>'latitudeA')::double precision,start_seq+(x->>'orderA')::integer-1,
  'broad'
 FROM jsonb_array_elements(p_pairs) x;
 INSERT INTO public.assignments
  (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,v_b,(x->>'pairId')::uuid,(x->>'longitudeB')::double precision,
  (x->>'latitudeB')::double precision,start_seq+(x->>'orderB')::integer-1,
  'broad'
 FROM jsonb_array_elements(p_pairs) x;
 RETURN jsonb_build_object('batchId',v_batch_id,'addedPairs',20,
    'firstSequence',start_seq,'alreadyCommitted',false);
END $$;

REVOKE ALL ON FUNCTION public.liminal_admin_commit_focused_batch(
 uuid,uuid,integer,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.liminal_admin_commit_focused_batch(
 uuid,uuid,integer,integer,text,jsonb,jsonb) TO service_role;
COMMIT;

-- Read-only verification separately: check batch_kind and focus_polygons
-- columns, table ACLs, no final batch yet, and function permissions.
