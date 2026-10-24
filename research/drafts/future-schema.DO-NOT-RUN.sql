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
  approved_pair_limit integer not null default 100 check(approved_pair_limit>=100),
  plan_closed boolean not null default false,
  adaptive_percent smallint not null default 50
    check(adaptive_percent between 0 and 100),
  batch_size smallint not null default 20
    check(batch_size between 1 and 30),
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
-- Only the authenticated admin may eventually edit adaptive_percent and batch_size
-- through an audited, server-validated RPC. Changes apply to new batches only.
-- They must NEVER replan existing staged/released sites, alter original 100,
-- expose private data, or automatically adjust final_pair_count.
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
-- Personal mapping now collects two-dot relative comparisons, NOT 1-10 scores.
-- The private backend must keep which dot was the original reference separate
-- from the participant-facing two points. No original ratings are model inputs.
create table if not exists public.liminal_personal_comparisons (
  id uuid primary key default gen_random_uuid(),
  study_id uuid not null references public.studies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  region_id uuid not null references public.liminal_personal_regions(id) on delete cascade,
  point_a jsonb not null,
  point_b jsonb not null,
  original_reference_is_a boolean not null,
  feeling text not null check(length(feeling) between 2 and 120),
  response_choice text check(response_choice in
    ('A','B','equal','neither','different')),
  note text not null default '' check(length(note)<=4000),
  presented_at timestamptz,
  responded_at timestamptz
);
-- Never reveal original_reference_is_a or prior responses to the user.
-- A future SECURITY DEFINER RPC will return only A/B points and feeling,
-- then accept a participant's relative answer. Strict user ownership
-- and phase separation MUST be checked in that server RPC.
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
alter table public.liminal_personal_comparisons enable row level security;
alter table public.liminal_reveal_audit enable row level security;
revoke all on public.liminal_sampling_plans,public.liminal_adaptive_batches,
  public.liminal_adaptive_pair_staging,public.liminal_personal_sessions,
  public.liminal_personal_regions,public.liminal_personal_locations,
  public.liminal_personal_feelings,public.liminal_personal_comparisons,
  public.liminal_reveal_audit from public,anon,authenticated;
-- No ALTER TABLE to existing studies/assignments/responses is in this draft.
-- No views, GRANTs, RPCs, or release triggers are installed here.
