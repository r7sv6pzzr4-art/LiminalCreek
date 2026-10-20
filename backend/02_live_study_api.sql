-- LiminalCreek: secure API for live observations. Run once in Supabase SQL Editor.
-- Does NOT activate collection. Use the separate activation query after testing.
ALTER TABLE public.studies ADD COLUMN IF NOT EXISTS started_at timestamptz;
DROP POLICY IF EXISTS "user can view own assignments" ON public.assignments;
REVOKE ALL ON public.assignments FROM anon,authenticated;
REVOKE ALL ON public.responses FROM anon,authenticated;

-- No direct browsing of the assignment queue. Return one next location only.
CREATE OR REPLACE FUNCTION public.next_liminal_place()
RETURNS TABLE(assignment_id uuid, longitude double precision, latitude double precision,
  completed bigint, completed_today bigint, started boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=''
AS $$
DECLARE sid uuid; uid uuid := auth.uid(); active boolean;
BEGIN
 IF uid IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
 SELECT s.id,s.started_at IS NOT NULL INTO sid,active
 FROM public.studies s JOIN public.participants p ON p.study_id=s.id
 WHERE p.user_id=uid AND s.revealed_at IS NULL
 ORDER BY s.created_at LIMIT 1;
 IF sid IS NULL THEN RAISE EXCEPTION 'This account is not assigned to a study'; END IF;
 RETURN QUERY
 SELECT CASE WHEN active AND coalesce(d.today_count,0)<10 THEN a.id ELSE NULL::uuid END,
        CASE WHEN active AND coalesce(d.today_count,0)<10 THEN a.longitude ELSE NULL::double precision END,
        CASE WHEN active AND coalesce(d.today_count,0)<10 THEN a.latitude ELSE NULL::double precision END,
        (SELECT count(*) FROM public.responses rr WHERE rr.user_id=uid AND rr.study_id=sid)::bigint,
        coalesce(d.today_count,0)::bigint, active
 FROM (SELECT count(*)::bigint AS today_count FROM public.responses r
       WHERE r.user_id=uid AND r.study_id=sid
       AND (r.recorded_at AT TIME ZONE 'America/New_York')::date =
           (now() AT TIME ZONE 'America/New_York')::date) d
 LEFT JOIN LATERAL (
  SELECT aa.id,aa.longitude,aa.latitude FROM public.assignments aa
  WHERE aa.user_id=uid AND aa.study_id=sid AND NOT EXISTS
   (SELECT 1 FROM public.responses rr WHERE rr.assignment_id=aa.id)
  ORDER BY aa.sequence_no LIMIT 1
 ) a ON TRUE;
END $$;
REVOKE ALL ON FUNCTION public.next_liminal_place() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.next_liminal_place() TO authenticated;

CREATE OR REPLACE FUNCTION public.submit_impression(
 p_assignment_id uuid,p_valence text,p_descriptions text[],p_strength smallint,p_note text DEFAULT ''
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=''
AS $$
DECLARE uid uuid:=auth.uid(); a public.assignments%ROWTYPE; response_id uuid; daily_count integer;
BEGIN
 IF uid IS NULL THEN RAISE EXCEPTION 'Sign-in required'; END IF;
 -- Serialize each user's submissions, including across devices.
 PERFORM 1 FROM public.participants p WHERE p.user_id=uid FOR UPDATE;
 SELECT * INTO a FROM public.assignments aa WHERE aa.id=p_assignment_id AND aa.user_id=uid;
 IF NOT FOUND THEN RAISE EXCEPTION 'Assignment not found'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.participants p WHERE p.user_id=uid AND p.study_id=a.study_id)
 THEN RAISE EXCEPTION 'Study membership required'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.studies s WHERE s.id=a.study_id AND s.started_at IS NOT NULL AND s.revealed_at IS NULL)
 THEN RAISE EXCEPTION 'Study collection has not started'; END IF;
 IF EXISTS(SELECT 1 FROM public.responses rr WHERE rr.assignment_id=a.id) THEN RAISE EXCEPTION 'Already submitted'; END IF;
 IF EXISTS(SELECT 1 FROM public.assignments earlier WHERE earlier.user_id=uid AND earlier.study_id=a.study_id
 AND earlier.sequence_no<a.sequence_no AND NOT EXISTS(SELECT 1 FROM public.responses rr WHERE rr.assignment_id=earlier.id))
 THEN RAISE EXCEPTION 'Complete the next assigned location first'; END IF;
 SELECT count(*) INTO daily_count FROM public.responses r WHERE r.user_id=uid AND r.study_id=a.study_id
 AND (r.recorded_at AT TIME ZONE 'America/New_York')::date=(now() AT TIME ZONE 'America/New_York')::date;
 IF daily_count>=10 THEN RAISE EXCEPTION 'Daily limit reached'; END IF;
 IF p_valence IS NULL OR p_valence NOT IN ('good','bad','neutral','mixed')
 OR coalesce(cardinality(p_descriptions),0)=0 OR
 EXISTS(SELECT 1 FROM unnest(p_descriptions) d WHERE length(trim(d))=0 OR length(d)>250)
 OR cardinality(p_descriptions)>15
 THEN RAISE EXCEPTION 'Invalid description'; END IF;
 IF (p_valence='neutral' AND p_strength IS NOT NULL)
 OR (p_valence<>'neutral' AND (p_strength IS NULL OR p_strength NOT BETWEEN 1 AND 4))
 THEN RAISE EXCEPTION 'Invalid strength'; END IF;
 IF length(coalesce(p_note,''))>4000 THEN RAISE EXCEPTION 'Note too long'; END IF;
 INSERT INTO public.responses(assignment_id,study_id,user_id,valence,descriptions,strength,note)
 VALUES(a.id,a.study_id,uid,p_valence,p_descriptions,p_strength,coalesce(p_note,''))
 RETURNING id INTO response_id;
 RETURN response_id;
END $$;
REVOKE ALL ON FUNCTION public.submit_impression(uuid,text,text[],smallint,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.submit_impression(uuid,text,text[],smallint,text) TO authenticated;

-- Read-only policy sanity checks (query these separately after setup):
-- SELECT tablename,policyname,cmd FROM pg_policies WHERE schemaname='public';
-- SELECT id,started_at FROM public.studies;
