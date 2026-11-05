-- LIMINALCREEK STAGING BOOTSTRAP
-- TARGET ONLY: Supabase project mrelwvpixalfycfdarjf
--              https://mrelwvpixalfycfdarjf.supabase.co
-- NEVER execute this in the live study project.
-- No real participant identities, assignments, or responses are included.
--
-- REQUIRES: a NEW, EMPTY staging Supabase project.
-- This script fails closed if any of the four original study tables exist.
-- The SQL Editor connection is privileged, so double-check the project ref.
BEGIN;

DO $staging_guard$
BEGIN
  IF to_regclass('public.studies') IS NOT NULL
  OR to_regclass('public.participants') IS NOT NULL
  OR to_regclass('public.assignments') IS NOT NULL
  OR to_regclass('public.responses') IS NOT NULL THEN
    RAISE EXCEPTION 'STOP: Existing LiminalCreek tables found. This bootstrap is for a NEW EMPTY STAGING project only.';
  END IF;
END
$staging_guard$;


-- ===== 1. SECURE STUDY FOUNDATION =====
-- LiminalCreek secure shared-study foundation.
-- Apply using Supabase SQL Editor after creating the project.
-- Data are private by default; public anon access is not allowed.
create extension if not exists pgcrypto;
create table if not exists public.studies (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'LiminalCreek',
  polygons jsonb not null default '{"type":"FeatureCollection","features":[]}'::jsonb,
  revealed_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.participants (
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null,
  is_admin boolean not null default false,
  primary key(study_id,user_id)
);
-- Each user sees only their own assigned coordinate, never the matched coordinate.
create table if not exists public.assignments (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  pair_id uuid not null,
  longitude double precision not null check(longitude between -180 and 180),
  latitude double precision not null check(latitude between -90 and 90),
  sequence_no integer not null,
  sampling_type text not null default 'broad' check(sampling_type in ('broad','adaptive','repeat')),
  created_at timestamptz not null default now(),
  unique(study_id,user_id,sequence_no)
);
create table if not exists public.responses (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null unique references public.assignments(id) on delete restrict,
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  valence text not null check(valence in ('good','bad','neutral','mixed')),
  descriptions text[] not null,
  strength smallint check(strength between 1 and 4),
  note text not null default '',
  recorded_at timestamptz not null default now(),
  check ((valence='neutral' and strength is null) or (valence<>'neutral' and strength is not null)),
  check (cardinality(descriptions)>0),
  check (length(note)<=4000)
);
create index if not exists idx_assignments_next on public.assignments(study_id,user_id,sequence_no);
create index if not exists idx_responses_user_time on public.responses(user_id,recorded_at);

alter table public.studies enable row level security;
alter table public.participants enable row level security;
alter table public.assignments enable row level security;
alter table public.responses enable row level security;

-- Membership verification is private and never exposes the other participant's identity.
create or replace function public.is_member(p_study uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.participants where study_id=p_study and user_id=auth.uid()) $$;
revoke all on function public.is_member(uuid) from public;
grant execute on function public.is_member(uuid) to authenticated;

create policy "members can read study settings" on public.studies for select to authenticated
 using (public.is_member(id));
create policy "user can see own membership" on public.participants for select to authenticated
 using (user_id=auth.uid());
-- Each authenticated participant can read only their own assignment queue.
create policy "user can view own assignments" on public.assignments for select to authenticated
 using (user_id=auth.uid() and public.is_member(study_id));

-- Responses have no SELECT, UPDATE or DELETE policy. Even one's own
-- observations are hidden until a deliberately designed reveal RPC is added.
-- Insert is enforced by the database RPC rather than a broad insert policy.
create or replace function public.submit_impression(
 p_assignment_id uuid,p_valence text,p_descriptions text[],p_strength smallint,p_note text default ''
) returns uuid
language plpgsql security definer set search_path=public
as $$
declare a public.assignments%rowtype; new_id uuid; cnt integer;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select * into a from public.assignments where id=p_assignment_id and user_id=auth.uid();
 if not found then raise exception 'Assignment not found'; end if;
 if not public.is_member(a.study_id) then raise exception 'Not a study member'; end if;
 if exists(select 1 from public.studies where id=a.study_id and revealed_at is not null) then
  raise exception 'This study has been revealed';
 end if;
 -- Date boundaries are UTC for deterministic enforcement (replace with configured
 -- study-local timezone if local-day limits are essential).
 select count(*) into cnt from public.responses
  where user_id=auth.uid() and recorded_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
 if cnt>=10 then raise exception 'Daily limit reached'; end if;
 if p_valence not in ('good','bad','neutral','mixed') or coalesce(cardinality(p_descriptions),0)=0 then
  raise exception 'Invalid impression';
 end if;
 if (p_valence='neutral' and p_strength is not null) or
    (p_valence<>'neutral' and (p_strength is null or p_strength not between 1 and 4)) then
  raise exception 'Invalid strength';
 end if;
 -- Ensure respondents cannot submit assignments out of order.
 if exists(select 1 from public.assignments earlier
   where earlier.study_id=a.study_id and earlier.user_id=a.user_id
   and earlier.sequence_no<a.sequence_no
   and not exists(select 1 from public.responses rr where rr.assignment_id=earlier.id)) then
   raise exception 'Previous assignment must be completed first';
 end if;
 insert into public.responses(assignment_id,study_id,user_id,valence,descriptions,strength,note)
 values(a.id,a.study_id,auth.uid(),p_valence,p_descriptions,p_strength,coalesce(p_note,''))
 returning id into new_id;
 return new_id;
end $$;
revoke all on function public.submit_impression(uuid,text,text[],smallint,text) from public;
grant execute on function public.submit_impression(uuid,text,text[],smallint,text) to authenticated;

-- No client write policies for study creation, participant roster,
-- assignments, or revealed_at. Populate them with a trusted server/admin tool.
-- Do not put the Supabase service_role key in GitHub Pages.


-- ===== 2. PARTICIPANT COLLECTION RPC =====
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


-- ===== 3. PRIVATE ADAPTIVE ACTIVATION =====
-- DEVELOPMENT DRAFT ONLY. DO NOT APPLY TO PRODUCTION.
-- Purpose: one trusted administrator action generates and appends 10/20/30/40
-- matched shared-study pairs with a chosen 50/50 or 25/75 sampling mix.
-- No manual review is needed; the current set may be unfinished.
-- Run in a disposable Supabase database after schema and existing live API.
-- Never deploy until separate staging verification and explicit owner approval.
-- Participant tables and existing RPCs are NOT altered by this draft.

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


-- Required for this project's 'Automatically expose new tables: OFF'
-- setting. The service role is a trusted backend role only. Never send its
-- credentials to the participant app or publish them on GitHub.
GRANT USAGE ON SCHEMA public TO authenticated,service_role;
GRANT ALL PRIVILEGES ON TABLE public.studies,public.participants,
  public.assignments,public.responses,public.liminal_auto_batches TO service_role;

-- Participant browsers use authenticated RPCs only; never expose tables.
REVOKE ALL ON TABLE public.assignments,public.responses,
  public.liminal_auto_batches FROM anon,authenticated;

COMMIT;

-- A clean bootstrap leaves all five study tables empty. Run this after
-- the migration as a separate read-only verification query if desired:
-- SELECT 'studies' AS name, count(*) FROM public.studies
-- UNION ALL SELECT 'participants', count(*) FROM public.participants
-- UNION ALL SELECT 'assignments', count(*) FROM public.assignments
-- UNION ALL SELECT 'responses', count(*) FROM public.responses
-- UNION ALL SELECT 'auto_batches', count(*) FROM public.liminal_auto_batches;
