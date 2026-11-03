-- LiminalCreek focused production security inventory
-- READ-ONLY. Designed for manual inspection in Supabase SQL Editor.
-- No study observations, comments, coordinates, participant identities, or secrets are returned.
-- Never use the production database to test CREATE/ALTER/REVOKE/GRANT statements.
BEGIN TRANSACTION READ ONLY;

-- 1. Direct access privileges and RLS state for the four live study tables.
SELECT c.relname AS table_name,
       c.relrowsecurity AS rls_enabled,
       c.relforcerowsecurity AS force_rls,
       has_table_privilege('anon',c.oid,'SELECT') AS anon_select,
       has_table_privilege('authenticated',c.oid,'SELECT') AS member_select,
       has_table_privilege('authenticated',c.oid,'INSERT') AS member_insert,
       has_table_privilege('authenticated',c.oid,'UPDATE') AS member_update,
       has_table_privilege('authenticated',c.oid,'DELETE') AS member_delete
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public'
  AND c.relname IN ('studies','participants','assignments','responses')
  AND c.relkind IN ('r','p')
ORDER BY c.relname;

-- 2. Policy inventory. No row contents are accessed.
SELECT tablename,policyname,permissive,roles,cmd,qual,with_check
FROM pg_policies
WHERE schemaname='public'
  AND tablename IN ('studies','participants','assignments','responses')
ORDER BY tablename,policyname;

-- 3. Public RPC call privileges, SECURITY DEFINER status, owner and search_path.
-- Function bodies are intentionally not returned.
SELECT p.proname AS function_name,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       p.prosecdef AS security_definer,
       pg_get_userbyid(p.proowner) AS owner_role,
       (SELECT string_agg(x,', ' ORDER BY x)
          FROM unnest(coalesce(p.proconfig,ARRAY[]::text[])) x
          WHERE x LIKE 'search_path=%') AS search_path_setting,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon_execute,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS member_execute
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
ORDER BY p.proname,pg_get_function_identity_arguments(p.oid);

-- 4. Check whether proposal-only adaptive objects have accidentally appeared in production.
SELECT 'adaptive_tables' AS object_type,
       count(*) AS number_found
FROM information_schema.tables
WHERE table_schema='public' AND table_name LIKE 'liminal_%'
UNION ALL
SELECT 'admin_rpcs',count(*)
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname LIKE 'liminal_admin_%';

COMMIT;
