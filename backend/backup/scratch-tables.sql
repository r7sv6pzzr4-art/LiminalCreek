-- Tables used only in an ephemeral PostgreSQL recovery container.
-- Column types and order must match LiminalCreek's production tables.
-- NO foreign keys, RLS, or functions: this is a data-content verification
-- target, NOT a full Supabase restore.
create table public.studies (
  id uuid,
  name text,
  polygons jsonb,
  revealed_at timestamptz,
  created_at timestamptz,
  started_at timestamptz
);
create table public.participants (
  study_id uuid,
  user_id uuid,
  display_name text,
  is_admin boolean
);
create table public.assignments (
  id uuid,
  study_id uuid,
  user_id uuid,
  pair_id uuid,
  longitude double precision,
  latitude double precision,
  sequence_no integer,
  sampling_type text,
  created_at timestamptz
);
create table public.responses (
  id uuid,
  assignment_id uuid,
  study_id uuid,
  user_id uuid,
  valence text,
  descriptions text[],
  strength smallint,
  note text,
  recorded_at timestamptz
);
