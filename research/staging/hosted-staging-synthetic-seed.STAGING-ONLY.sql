-- LIMINALCREEK STAGING -- SYNTHETIC DATA ONLY
-- TARGET PROJECT: mrelwvpixalfycfdarjf
--                 https://mrelwvpixalfycfdarjf.supabase.co
-- DO NOT RUN IN YOUR LIVE LIMINALCREEK PROJECT.
--
-- Requirements:
--   1. Hosted staging bootstrap has been applied successfully.
--   2. The five staging study tables are all empty.
--   3. The two manually created synthetic Auth accounts exist:
--      staging-admin@example.invalid
--      staging-participant@example.invalid
--
-- This adds 100 matched assignment pairs plus 188 fictional responses:
--   synthetic administrator: 88 of 100 complete
--   synthetic other participant: 100 of 100 complete
-- No real participant emails, answers, locations, or service keys are used.
--
-- The transaction rolls back on any failed guard or insert.

BEGIN;

DO $synthetic_staging_seed$
DECLARE
  v_admin uuid;
  v_other uuid;
  v_study uuid := gen_random_uuid();
  v_pair uuid;
  v_assignment_a uuid;
  v_assignment_b uuid;
  v_lon double precision;
  v_lat double precision;
  v_i integer;
  v_n integer;
BEGIN
  -- Fail closed if this database already contains ANY study data.
  IF EXISTS(SELECT 1 FROM public.studies)
   OR EXISTS(SELECT 1 FROM public.participants)
   OR EXISTS(SELECT 1 FROM public.assignments)
   OR EXISTS(SELECT 1 FROM public.responses)
   OR EXISTS(SELECT 1 FROM public.liminal_auto_batches)
  THEN
    RAISE EXCEPTION 'STOP: Study data already present. Synthetic staging seed refused.';
  END IF;

  -- Look up test identities without requiring you to paste any user IDs.
  SELECT id INTO v_admin FROM auth.users
    WHERE email='staging-admin@example.invalid';
  SELECT id INTO v_other FROM auth.users
    WHERE email='staging-participant@example.invalid';

  IF v_admin IS NULL OR v_other IS NULL OR v_admin=v_other THEN
    RAISE EXCEPTION 'STOP: Expected two distinct staging Auth users not found.';
  END IF;

  -- Synthetic rectangular polygon unrelated to the actual study area.
  INSERT INTO public.studies (id,name,polygons,started_at)
  VALUES (
    v_study,
    'SYNTHETIC staging shared study - not real observations',
    jsonb_build_object(
      'type','FeatureCollection',
      'features',jsonb_build_array(
        jsonb_build_object(
          'type','Feature',
          'properties',jsonb_build_object('synthetic',true),
          'geometry',jsonb_build_object(
            'type','Polygon',
            'coordinates',jsonb_build_array(
              jsonb_build_array(
                jsonb_build_array(-74.19,40.300),
                jsonb_build_array(-74.14,40.300),
                jsonb_build_array(-74.14,40.350),
                jsonb_build_array(-74.19,40.350),
                jsonb_build_array(-74.19,40.300)
              )
            )
          )
        )
      )
    ),
    now()
  );

  INSERT INTO public.participants(study_id,user_id,display_name,is_admin)
  VALUES
    (v_study,v_admin,'Synthetic administrator',true),
    (v_study,v_other,'Synthetic participant',false);

  FOR v_i IN 1..100 LOOP
    v_pair:=gen_random_uuid();
    v_assignment_a:=gen_random_uuid();
    v_assignment_b:=gen_random_uuid();
    v_lon:=-74.187+((v_i-1)%10)*0.0047;
    v_lat:=40.303+floor((v_i-1)/10.0)*0.0047;

    -- Same pair ID, distinct participant coordinates, under 200 ft apart.
    INSERT INTO public.assignments(
      id,study_id,user_id,pair_id,sequence_no,
      longitude,latitude,sampling_type
    ) VALUES
      (v_assignment_a,v_study,v_admin,v_pair,v_i,
       v_lon,v_lat,'broad'),
      (v_assignment_b,v_study,v_other,v_pair,v_i,
       v_lon+0.00012,v_lat+0.00010,'broad');
  END LOOP;

  -- Use deliberately fictional responses, recorded in the past so the
  -- normal ten-per-day limit does not interfere with browser testing.
  INSERT INTO public.responses(
    assignment_id,study_id,user_id,valence,descriptions,
    strength,note,recorded_at
  )
  SELECT
    a.id,a.study_id,a.user_id,
    CASE WHEN a.sequence_no%13=0 THEN 'mixed' ELSE 'neutral' END,
    CASE WHEN a.sequence_no%13=0
      THEN ARRAY['synthetic strong impression']
      ELSE ARRAY['synthetic neutral impression'] END,
    CASE WHEN a.sequence_no%13=0 THEN 4::smallint ELSE NULL::smallint END,
    'SYNTHETIC TEST OBSERVATION - NOT REAL PARTICIPANT DATA',
    timestamptz '2026-01-10 09:00:00+00'
  FROM public.assignments a
  WHERE a.study_id=v_study
    AND (a.user_id=v_other OR
         (a.user_id=v_admin AND a.sequence_no<=88));

  SELECT count(*) INTO v_n FROM public.responses WHERE study_id=v_study;
  IF v_n<>188 THEN
    RAISE EXCEPTION 'STOP: Expected 188 synthetic responses, found %',v_n;
  END IF;

  IF (SELECT count(*) FROM public.assignments WHERE study_id=v_study)<>200
   OR (SELECT count(*) FROM public.participants WHERE study_id=v_study)<>2
   OR (SELECT count(DISTINCT pair_id) FROM public.assignments
       WHERE study_id=v_study)<>100
  THEN
    RAISE EXCEPTION 'STOP: Synthetic assignment inventory verification failed.';
  END IF;

  RAISE NOTICE 'SYNTHETIC STAGING seed complete: 100 pairs, 200 assignments, 188 responses.';
END
$synthetic_staging_seed$;

COMMIT;

-- Read-only counts displayed after successful seeding.
SELECT 'studies' AS table_name,count(*) AS rows FROM public.studies
UNION ALL SELECT 'participants',count(*) FROM public.participants
UNION ALL SELECT 'assignments',count(*) FROM public.assignments
UNION ALL SELECT 'responses',count(*) FROM public.responses
UNION ALL SELECT 'auto_batches',count(*) FROM public.liminal_auto_batches;
