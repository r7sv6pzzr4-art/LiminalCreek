-- Read-only setup checks. Run AFTER backend/02_live_study_api.sql
SELECT 'study' AS check_name, count(*)::text AS result FROM public.studies
 WHERE id='664b110e-7d5e-445e-815c-986430baf9bd'
UNION ALL SELECT 'members',count(*)::text FROM public.participants
 WHERE study_id='664b110e-7d5e-445e-815c-986430baf9bd'
UNION ALL SELECT 'assignments',count(*)::text FROM public.assignments
 WHERE study_id='664b110e-7d5e-445e-815c-986430baf9bd'
UNION ALL SELECT 'responses',count(*)::text FROM public.responses
 WHERE study_id='664b110e-7d5e-445e-815c-986430baf9bd'
UNION ALL SELECT 'not_started',count(*)::text FROM public.studies
 WHERE id='664b110e-7d5e-445e-815c-986430baf9bd'
 AND started_at IS NULL
UNION ALL SELECT 'assignments_rls',relrowsecurity::text FROM pg_class
 WHERE oid='public.assignments'::regclass
UNION ALL SELECT 'responses_rls',relrowsecurity::text FROM pg_class
 WHERE oid='public.responses'::regclass
UNION ALL SELECT 'assignments_direct_read_blocked',
 (NOT has_table_privilege('authenticated','public.assignments','SELECT'))::text
UNION ALL SELECT 'responses_direct_read_blocked',
 (NOT has_table_privilege('authenticated','public.responses','SELECT'))::text;
