-- PROPOSAL ONLY: DO NOT APPLY TO THE LIVE SUPABASE DATABASE.
-- LiminalCreek future adaptive and personal-study tables.
-- File is deliberately OUTSIDE backend/ migrations and is not executed by the app.
-- This proposal adds no policy permitting clients to read source observations.
--
-- Before ANY deployment: export a private database backup, audit original
-- 100 pairs + assignment sequences + responses, and review SQL/RPC privileges.

-- Sampling plan closure must be explicit; an empty assignment queue is NOT
-- evidence that the shared study has ended.
create table if not exists public.liminal_sampling_plans (
  study_id uuid primary key references public.studies(id) on delete cascade,
  original_pair_count integer not null default 100 check (original_pair_count=100),
  final_pair_count integer check (final_pair_count>=100),
  plan_closed boolean not null default false,
  activated_at timestamptz,
  closed_at timestamptz,
  check (not plan_closed or final_pair_count is not null)
);
create table if not exists public.liminal_adaptive_batches (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null references public.studies(id) on delete cascade,
  batch_no integer not null check(batch_no>0),
  seed text not null,
  algorithm_version text not null,
  source_snapshot_at timestamptz not null,
  source_response_count integer not null check(source_response_count>=0),
  state text not null default 'staged' check(state in ('staged','released','cancelled')),
  created_at timestamptz not null default now(),
  released_at timestamptz,
  unique(study_id,batch_no)
);
create table if not exists public.liminal_adaptive_pair_staging (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.liminal_adaptive_batches(id) on delete cascade,
  pair_index integer not null check(pair_index>0),
  sampling_mode text not null check(sampling_mode in ('interesting','uncertain','quiet','broad')),
  a_longitude double precision not null check(a_longitude between -180 and 180),
  a_latitude double precision not null check(a_latitude between -90 and 90),
  b_longitude double precision not null check(b_longitude between -180 and 180),
  b_latitude double precision not null check(b_latitude between -90 and 90),
  maximum_separation_meters double precision not null
    check(maximum_separation_meters>0 and maximum_separation_meters<=60.96),
  unique(batch_id,pair_index)
);
-- DO NOT create a trigger that inserts staged pairs into public.assignments.
-- A separate reviewed, transactional promotion process must:
--   * wait until BOTH finish all original 100 assignments,
--   * append new sequence numbers >100 without changing earlier rows,
--   * use same pair ID for both participants with independently shuffled
--     order inside each batch, and NEVER expose a partner coordinate,
--   * lock and verify the expected batch, pair count and snapshot,
--   * reject duplicate promotion and preserve every completed response.

create table if not exists public.liminal_personal_sessions (
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'not_started'
    check(status in ('not_started','active','completed','skipped')),
  offered_at timestamptz,
  completed_at timestamptz,
  primary key(study_id,user_id)
);
create table if not exists public.liminal_personal_regions (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  approximate_center jsonb not null,
  approximate_radius_meters double precision not null
    check(approximate_radius_meters>=100),
  suggested_feelings text[] not null default '{}',
  unique(id,study_id,user_id)
);
create table if not exists public.liminal_personal_locations (
  id uuid primary key default gen_random_uuid(),
  region_id uuid not null references public.liminal_personal_regions(id) on delete cascade,
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  sequence_no integer not null check(sequence_no>0),
  longitude double precision not null check(longitude between -180 and 180),
  latitude double precision not null check(latitude between -90 and 90),
  unique(study_id,user_id,sequence_no),
  unique(id,study_id,user_id)
);
create table if not exists public.liminal_personal_feelings (
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  label text not null check(length(label) between 2 and 120),
  created_at timestamptz not null default now(),
  primary key(study_id,user_id,label)
);
create table if not exists public.liminal_personal_responses (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null,
  user_id uuid not null,
  location_id uuid not null,
  feeling text not null,
  intensity smallint check(intensity between 1 and 10),
  note text not null default '' check(length(note)<=4000),
  recorded_at timestamptz not null default now(),
  foreign key(location_id,study_id,user_id)
    references public.liminal_personal_locations(id,study_id,user_id),
  unique(location_id),
  check((feeling='none' and intensity is null)
    or (feeling<>'none' and intensity is not null))
);
create table if not exists public.liminal_reveal_audit (
  study_id uuid primary key references public.studies(id) on delete cascade,
  authorized_by uuid not null references auth.users(id),
  released_at timestamptz not null default now()
);
-- Deny all client access until explicitly reviewed and individually scoped
-- SECURITY DEFINER functions have been implemented and tested.
alter table public.liminal_sampling_plans enable row level security;
alter table public.liminal_adaptive_batches enable row level security;
alter table public.liminal_adaptive_pair_staging enable row level security;
alter table public.liminal_personal_sessions enable row level security;
alter table public.liminal_personal_regions enable row level security;
alter table public.liminal_personal_locations enable row level security;
alter table public.liminal_personal_feelings enable row level security;
alter table public.liminal_personal_responses enable row level security;
alter table public.liminal_reveal_audit enable row level security;
revoke all on public.liminal_sampling_plans,public.liminal_adaptive_batches,
  public.liminal_adaptive_pair_staging,public.liminal_personal_sessions,
  public.liminal_personal_regions,public.liminal_personal_locations,
  public.liminal_personal_feelings,public.liminal_personal_responses,
  public.liminal_reveal_audit from public,anon,authenticated;
-- No ALTER TABLE to existing studies/assignments/responses is in this draft.
-- No views, GRANTs, RPCs, or release triggers are installed here.
