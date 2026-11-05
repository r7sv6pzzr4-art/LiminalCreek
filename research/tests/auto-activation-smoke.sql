-- Synthetic, throwaway PostgreSQL test. NEVER execute against live Supabase.
\set ON_ERROR_STOP on
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE anon NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
 SELECT nullif(current_setting('request.jwt.claim.role',true),'')::text $;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
CREATE TABLE public.studies (
 id uuid primary key,created_at timestamptz default now(),
 started_at timestamptz,revealed_at timestamptz
);
CREATE TABLE public.participants (
 study_id uuid not null,user_id uuid not null,
 display_name text,is_admin boolean not null default false,
 primary key(study_id,user_id)
);
CREATE TABLE public.assignments (
 id uuid primary key default gen_random_uuid(),
 study_id uuid not null,user_id uuid not null,pair_id uuid not null,
 sequence_no integer not null,longitude double precision not null,
 latitude double precision not null,sampling_type text not null default 'broad',
 UNIQUE(study_id,user_id,sequence_no)
);
CREATE TABLE public.responses (
 id uuid primary key default gen_random_uuid(),assignment_id uuid unique not null,
 study_id uuid not null,user_id uuid not null,valence text not null,strength smallint
);
-- Production-like RLS: no direct response or assignment access for authenticated.
ALTER TABLE public.assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.participants ENABLE ROW LEVEL SECURITY;
INSERT INTO public.studies(id,started_at) VALUES
 ('11111111-1111-4111-8111-111111111111',now());
INSERT INTO public.participants(study_id,user_id,display_name,is_admin) VALUES
 ('11111111-1111-4111-8111-111111111111','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','Admin',true),
 ('11111111-1111-4111-8111-111111111111'::uuid,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,'Brother',false);
WITH pairs AS (
 SELECT n,gen_random_uuid() AS pair_id FROM generate_series(1,100) n
)
INSERT INTO public.assignments
 (study_id,user_id,pair_id,sequence_no,longitude,latitude,sampling_type)
SELECT '11111111-1111-4111-8111-111111111111'::uuid, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'::uuid,
 pair_id,n,-74.17+n*0.00008,40.32,'broad' FROM pairs
UNION ALL
SELECT '11111111-1111-4111-8111-111111111111'::uuid,'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'::uuid,
 pair_id,n,-74.1699+n*0.00008,40.3201,'broad' FROM pairs;
INSERT INTO public.responses(assignment_id,study_id,user_id,valence,strength)
 SELECT id,study_id,user_id,'neutral',NULL FROM public.assignments;
CREATE TEMP TABLE original_hash AS SELECT
 md5(string_agg(row_to_json(a)::text,'' ORDER BY a.id)) as hash
 FROM public.assignments a WHERE sequence_no<=100;

\ir ../drafts/auto-activation.DO-NOT-RUN.sql

-- Authenticated member without administrator role must not receive status.
SET ROLE authenticated;
SET request.jwt.claim.role = 'authenticated';
SET request.jwt.claim.sub = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
DO $$
BEGIN
 BEGIN
  PERFORM public.liminal_admin_auto_status();
  RAISE EXCEPTION 'TEST_FAILURE_NONADMIN_ALLOWED';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='TEST_FAILURE_NONADMIN_ALLOWED' THEN RAISE; END IF;
 END;
END $$;

-- Admin may read status but cannot submit arbitrary coordinates directly.
SET request.jwt.claim.sub = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
DO $
DECLARE stat jsonb;
BEGIN
 stat:=public.liminal_admin_auto_status();
 IF (stat->>'canActivate')::boolean IS DISTINCT FROM true
 THEN RAISE EXCEPTION 'Expected eligible full-original study'; END IF;
 IF has_function_privilege('authenticated','public.liminal_admin_commit_auto_batch(uuid,uuid,integer,integer,text,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'Client may execute coordinate insertion RPC'; END IF;
END $;
RESET ROLE;
SET ROLE service_role;
SET request.jwt.claim.role = 'service_role';
-- Only trusted coordinator may commit a generated manifest.
DO $
DECLARE manifest jsonb; outcome jsonb;
BEGIN
 SELECT jsonb_agg(jsonb_build_object(
   'pairId',gen_random_uuid(),'mode',CASE WHEN n<=10 THEN 'broad' ELSE 'interesting' END,
   'longitudeA',-74.17+n*0.00008,'latitudeA',40.32,
   'longitudeB',-74.1699+n*0.00008,'latitudeB',40.3201,
   'orderA',n,'orderB',21-n,'adaptivePercent',50
 ) ORDER BY n) INTO manifest FROM generate_series(1,20) n;
 outcome:=public.liminal_admin_commit_auto_batch(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',200,200,
  'synthetic-fixed-long-seed',manifest);
 IF (outcome->>'addedPairs')::integer<>20 OR (outcome->>'firstSequence')::integer<>101
 THEN RAISE EXCEPTION 'Unexpected release outcome'; END IF;
 -- A double-click with a different ID may not append while queues are unfinished.
 BEGIN
  PERFORM public.liminal_admin_commit_auto_batch(
   'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
   'dddddddd-dddd-4ddd-8ddd-dddddddddddd',240,200,
   'synthetic-fixed-long-seed',manifest);
  RAISE EXCEPTION 'TEST_FAILURE_DOUBLE_RELEASE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN
  IF SQLERRM='TEST_FAILURE_DOUBLE_RELEASE_ALLOWED' THEN RAISE; END IF;
 END;
 -- Same request ID is idempotent even after the queue changes.
 outcome:=public.liminal_admin_commit_auto_batch(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'cccccccc-cccc-4ccc-8ccc-cccccccccccc',200,200,
  'synthetic-fixed-long-seed',manifest);
 IF (outcome->>'alreadyCommitted')::boolean IS DISTINCT FROM true THEN
  RAISE EXCEPTION 'Activation retry was not idempotent';
 END IF;
END $$;
RESET ROLE;

DO $$
DECLARE prev text; after text;
BEGIN
 SELECT hash INTO prev FROM original_hash;
 SELECT md5(string_agg(row_to_json(a)::text,'' ORDER BY a.id)) INTO after
 FROM public.assignments a WHERE sequence_no<=100;
 IF prev<>after THEN RAISE EXCEPTION 'Original 200 assignments mutated'; END IF;
 IF (SELECT count(*) FROM public.assignments)<>240
 OR (SELECT count(*) FROM public.responses)<>200
 OR (SELECT count(*) FROM public.liminal_auto_batches)<>1
 THEN RAISE EXCEPTION 'Unexpected assignment, response or batch count'; END IF;
 IF EXISTS(SELECT 1 FROM public.participants p
  WHERE (SELECT count(*) FROM public.assignments a
   WHERE a.user_id=p.user_id AND a.sequence_no BETWEEN 101 AND 120)<>20)
 THEN RAISE EXCEPTION 'Missing appended locations for a participant'; END IF;
 IF (SELECT count(DISTINCT pair_id) FROM public.assignments
     WHERE sequence_no>100)<>20
 THEN RAISE EXCEPTION 'Appended pair mismatch'; END IF;
END $$;
-- Simulate both completing locations 101–120 before a second activation.
INSERT INTO public.responses(assignment_id,study_id,user_id,valence,strength)
 SELECT a.id,a.study_id,a.user_id,'neutral',NULL
 FROM public.assignments a WHERE a.sequence_no BETWEEN 101 AND 120;
SET ROLE service_role;
SET request.jwt.claim.role = 'service_role';
DO $
DECLARE manifest jsonb; result jsonb;
BEGIN
 SELECT jsonb_agg(jsonb_build_object(
  'pairId',gen_random_uuid(),'mode',CASE WHEN mod(n,2)=0 THEN 'broad' ELSE 'interesting' END,
  'longitudeA',-74.165+n*0.00005,'latitudeA',40.325,
  'longitudeB',-74.1649+n*0.00005,'latitudeB',40.3251,
  'orderA',n,'orderB',41-n,
  'adaptivePercent',CASE WHEN n<=20 THEN 50 ELSE 75 END
 ) ORDER BY n) INTO manifest FROM generate_series(1,40) n;
 result:=public.liminal_admin_commit_auto_batch(
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',240,240,
  'synthetic-second-long-seed',manifest);
 IF (result->>'addedPairs')::integer<>40 OR (result->>'firstSequence')::integer<>121
 THEN RAISE EXCEPTION '40-pair activation failed'; END IF;
END $$;
RESET ROLE;
DO $$
BEGIN
 IF (SELECT count(*) FROM public.assignments)<>320 OR
    (SELECT count(*) FROM public.responses)<>240 OR
    (SELECT count(*) FROM public.liminal_auto_batches)<>2
 THEN RAISE EXCEPTION '40-pair append has wrong totals'; END IF;
 IF (SELECT count(DISTINCT pair_id) FROM public.assignments
     WHERE sequence_no BETWEEN 121 AND 160)<>40
 THEN RAISE EXCEPTION '40 appended pair IDs do not match'; END IF;
 IF (SELECT hash FROM original_hash) <> (
   SELECT md5(string_agg(row_to_json(a)::text,'' ORDER BY a.id))
   FROM public.assignments a WHERE a.sequence_no<=100)
 THEN RAISE EXCEPTION 'Original assignments modified after second release'; END IF;
END $$;
SELECT 'PASS: role restrictions, 20 and 40 matched-pair activations, idempotence, originals unchanged' AS result;

