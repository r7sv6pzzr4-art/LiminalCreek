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
