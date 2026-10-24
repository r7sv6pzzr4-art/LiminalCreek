-- DRAFT ONLY. Do not execute on the live database.
-- Requires future-schema.DO-NOT-RUN.sql and a private staging coordinator.
-- PostgreSQL functions below must be security-reviewed and tested in staging.
-- Existing responses/assignments are never updated or deleted.

-- One-time grants are deliberately omitted here. The future deployment must
-- explicitly REVOKE all and GRANT EXECUTE only to authenticated on approved RPCs.

CREATE OR REPLACE FUNCTION public.liminal_admin_progress()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; result jsonb;
BEGIN
 SELECT p.study_id INTO sid FROM public.participants p
 WHERE p.user_id=auth.uid() AND p.is_admin;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator required'; END IF;
 SELECT jsonb_build_object(
   'studyId', sid,
   'participants',(
      SELECT jsonb_agg(jsonb_build_object(
        'participant', p.display_name,
        'completed', (SELECT count(*) FROM public.responses r
                      WHERE r.study_id=sid AND r.user_id=p.user_id),
        'assigned', (SELECT count(*) FROM public.assignments a
                     WHERE a.study_id=sid AND a.user_id=p.user_id),
        'originalCompleted', (SELECT count(*) FROM public.responses r
                        JOIN public.assignments a ON a.id=r.assignment_id
                        WHERE r.study_id=sid AND r.user_id=p.user_id AND a.sequence_no<=100)
      ) ORDER BY p.display_name)
      FROM public.participants p WHERE p.study_id=sid
   ),
   'settings',(SELECT jsonb_build_object(
        'adaptivePercent',sp.adaptive_percent,'batchSize',sp.batch_size,
        'planClosed',sp.plan_closed,'finalPairCount',sp.final_pair_count
      ) FROM public.liminal_sampling_plans sp WHERE sp.study_id=sid),
   'stagedBatches',(SELECT count(*) FROM public.liminal_adaptive_batches b
                    WHERE b.study_id=sid AND b.state='staged')
 ) INTO result;
 RETURN result;
END $$;

CREATE OR REPLACE FUNCTION public.liminal_admin_set_sampling(
 p_percent smallint, p_batch_size smallint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; sp public.liminal_sampling_plans%ROWTYPE;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
 SELECT p.study_id INTO sid FROM public.participants p
 WHERE p.user_id=auth.uid() AND p.is_admin;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator required'; END IF;
 IF p_percent IS NULL OR p_percent NOT BETWEEN 0 AND 100
 OR p_batch_size IS NULL OR p_batch_size NOT BETWEEN 1 AND 30
 THEN RAISE EXCEPTION 'Invalid sampling settings'; END IF;
 SELECT * INTO sp FROM public.liminal_sampling_plans
 WHERE study_id=sid FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sampling plan not initialized'; END IF;
 IF sp.plan_closed THEN RAISE EXCEPTION 'Sampling plan already closed'; END IF;
 UPDATE public.liminal_sampling_plans
 SET adaptive_percent=p_percent,batch_size=p_batch_size
 WHERE study_id=sid;
 -- Settings are only read by the generator when CREATING a future batch.
 RETURN jsonb_build_object('adaptivePercent',p_percent,'batchSize',p_batch_size);
END $$;

-- Promotion accepts NO coordinates from a browser. It reads immutable frozen
-- stage records generated using private observations in a trusted environment.
-- The order keys are stored with the frozen batch before promotion; see
-- recommended schema extension below. The caller only supplies a batch UUID.
ALTER TABLE public.liminal_adaptive_pair_staging
 ADD COLUMN IF NOT EXISTS sequence_a integer,
 ADD COLUMN IF NOT EXISTS sequence_b integer;
CREATE UNIQUE INDEX IF NOT EXISTS liminal_stage_order_a
 ON public.liminal_adaptive_pair_staging(batch_id,sequence_a)
 WHERE sequence_a IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS liminal_stage_order_b
 ON public.liminal_adaptive_pair_staging(batch_id,sequence_b)
 WHERE sequence_b IS NOT NULL;

CREATE OR REPLACE FUNCTION public.liminal_admin_release_batch(p_batch_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; b public.liminal_adaptive_batches%ROWTYPE;
        members uuid[]; total integer; next_a integer; next_b integer;
        stage_pairs integer; inserted integer;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
 SELECT p.study_id INTO sid FROM public.participants p
 WHERE p.user_id=auth.uid() AND p.is_admin;
 IF sid IS NULL THEN RAISE EXCEPTION 'Administrator required'; END IF;
 -- Serialize all promotions and settings changes for this study.
 PERFORM 1 FROM public.liminal_sampling_plans s
 WHERE s.study_id=sid AND NOT s.plan_closed FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Sampling plan not active'; END IF;
 SELECT * INTO b FROM public.liminal_adaptive_batches
 WHERE id=p_batch_id AND study_id=sid FOR UPDATE;
 IF NOT FOUND OR b.state<>'staged' THEN RAISE EXCEPTION 'Batch not staged'; END IF;
 SELECT array_agg(p.user_id ORDER BY p.user_id) INTO members
 FROM public.participants p WHERE p.study_id=sid;
 IF coalesce(array_length(members,1),0)<>2
 THEN RAISE EXCEPTION 'Exactly two participants required'; END IF;
 SELECT count(*) INTO total FROM public.assignments a WHERE a.study_id=sid;
 IF total<>2*(SELECT count(*) FROM public.assignments a
              WHERE a.study_id=sid AND a.user_id=members[1])
 OR total<>2*(SELECT count(*) FROM public.assignments a
              WHERE a.study_id=sid AND a.user_id=members[2])
 THEN RAISE EXCEPTION 'Participant queue lengths differ'; END IF;
 -- Original 100 untouched; count and completion checked for each member.
 IF EXISTS (
   SELECT 1 FROM unnest(members) uid
   WHERE (SELECT count(*) FROM public.assignments a
          WHERE a.study_id=sid AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
      OR (SELECT count(*) FROM public.assignments a
          JOIN public.responses r ON r.assignment_id=a.id
          WHERE a.study_id=sid AND a.user_id=uid AND a.sequence_no BETWEEN 1 AND 100)<>100
 ) THEN RAISE EXCEPTION 'Both original cohorts must be complete'; END IF;
 SELECT coalesce(max(sequence_no),0)+1 INTO next_a
 FROM public.assignments WHERE study_id=sid AND user_id=members[1];
 SELECT coalesce(max(sequence_no),0)+1 INTO next_b
 FROM public.assignments WHERE study_id=sid AND user_id=members[2];
 IF next_a<>next_b OR next_a<=100
 THEN RAISE EXCEPTION 'Unexpected sequence state'; END IF;
 SELECT count(*) INTO stage_pairs FROM public.liminal_adaptive_pair_staging
 WHERE batch_id=b.id;
 IF stage_pairs<1 OR stage_pairs>30 OR
    (SELECT count(DISTINCT sequence_a) FROM public.liminal_adaptive_pair_staging
     WHERE batch_id=b.id)<>stage_pairs OR
    (SELECT count(DISTINCT sequence_b) FROM public.liminal_adaptive_pair_staging
     WHERE batch_id=b.id)<>stage_pairs OR
    EXISTS(SELECT 1 FROM public.liminal_adaptive_pair_staging
           WHERE batch_id=b.id AND (sequence_a NOT BETWEEN 1 AND stage_pairs
                                    OR sequence_b NOT BETWEEN 1 AND stage_pairs))
 THEN RAISE EXCEPTION 'Frozen batch sequence invalid'; END IF;
 IF EXISTS(SELECT 1 FROM public.assignments a
           JOIN public.liminal_adaptive_pair_staging s ON s.id=a.pair_id
           WHERE s.batch_id=b.id)
 THEN RAISE EXCEPTION 'Batch already referenced by assignments'; END IF;
 -- A/B identity is stable: lexically first UUID gets A, second gets B.
 INSERT INTO public.assignments
 (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,members[1],s.id,s.a_longitude,s.a_latitude,
        next_a+s.sequence_a-1,
        CASE WHEN s.sampling_mode='broad' THEN 'broad' ELSE 'adaptive' END
 FROM public.liminal_adaptive_pair_staging s WHERE s.batch_id=b.id;
 GET DIAGNOSTICS inserted=ROW_COUNT;
 IF inserted<>stage_pairs THEN RAISE EXCEPTION 'A insertion count mismatch'; END IF;
 INSERT INTO public.assignments
 (study_id,user_id,pair_id,longitude,latitude,sequence_no,sampling_type)
 SELECT sid,members[2],s.id,s.b_longitude,s.b_latitude,
        next_b+s.sequence_b-1,
        CASE WHEN s.sampling_mode='broad' THEN 'broad' ELSE 'adaptive' END
 FROM public.liminal_adaptive_pair_staging s WHERE s.batch_id=b.id;
 GET DIAGNOSTICS inserted=ROW_COUNT;
 IF inserted<>stage_pairs THEN RAISE EXCEPTION 'B insertion count mismatch'; END IF;
 UPDATE public.liminal_adaptive_batches
 SET state='released',released_at=now() WHERE id=b.id;
 RETURN jsonb_build_object('batchId',b.id,'newPairs',stage_pairs);
END $$;

-- Deployment requirements: untrusted callers must be unable to insert/change
-- staging rows; revoke ALL on tables from PUBLIC, anon and authenticated,
-- and enforce membership/ownership within every RPC. The administrator
-- must NOT be given direct SELECT on responses or paired coordinates.
-- No schema above is live unless explicitly reviewed and executed.
