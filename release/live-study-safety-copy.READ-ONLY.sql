-- LiminalCreek LIVE STUDY SAFETY COPY — READ ONLY
-- Target: the original live Supabase project, NOT the staging project.
-- This is a study-level data copy, NOT a complete database backup.
-- It contains real participant identifiers and private free-text COMMENTS.
-- Export the one-row result to a PRIVATE local file, preferably encrypted.
-- NEVER paste the result in ChatGPT, commit to GitHub, or upload publicly.
-- Run before the additive production migration and again if release is delayed.
BEGIN TRANSACTION READ ONLY;
WITH active AS (
 SELECT s.id FROM public.studies s
 WHERE s.started_at IS NOT NULL AND s.revealed_at IS NULL
)
SELECT jsonb_build_object(
 'format','liminalcreek-live-study-safety-copy-v1',
 'exportedAt',statement_timestamp(),
 'studyCount',(SELECT count(*) FROM active),
 'studies',(SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.id),'[]'::jsonb)
   FROM public.studies s JOIN active x ON x.id=s.id),
 'participants',(SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.user_id),'[]'::jsonb)
   FROM public.participants p JOIN active x ON x.id=p.study_id),
 'assignments',(SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id),'[]'::jsonb)
   FROM public.assignments a JOIN active x ON x.id=a.study_id),
 'responses',(SELECT coalesce(jsonb_agg(to_jsonb(rr) ORDER BY rr.id),'[]'::jsonb)
   FROM public.responses rr JOIN active x ON x.id=rr.study_id),
 'rowCounts',jsonb_build_object(
  'participants',(SELECT count(*) FROM public.participants p JOIN active x ON x.id=p.study_id),
  'assignments',(SELECT count(*) FROM public.assignments a JOIN active x ON x.id=a.study_id),
  'responses',(SELECT count(*) FROM public.responses rr JOIN active x ON x.id=rr.study_id)
 )
)::text AS private_study_backup_json;
COMMIT;
