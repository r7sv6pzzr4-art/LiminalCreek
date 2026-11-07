-- LiminalCreek: READ-ONLY data health report.
-- Run in Supabase SQL Editor under project administrator privileges.
-- Never displays coordinates, selected feelings, comments, user IDs, or raw data.
-- Counts are for monitoring only, not proof that a backup is restorable.
WITH original AS (
  SELECT a.pair_id, a.user_id, a.sequence_no
  FROM public.assignments a
  WHERE a.sequence_no BETWEEN 1 AND 100
), pair_sides AS (
  SELECT pair_id, count(*) AS sides, count(DISTINCT user_id) AS people
  FROM original
  GROUP BY pair_id
), resp AS (
  SELECT
    count(*) AS responses_saved,
    count(*) FILTER (WHERE cardinality(descriptions) > 0) AS with_feeling_descriptions,
    count(*) FILTER (WHERE length(btrim(coalesce(note, ''))) > 0) AS with_written_comments,
    count(*) FILTER (WHERE valence = 'neutral' AND strength IS NULL
                     OR valence <> 'neutral' AND strength BETWEEN 1 AND 4)
      AS with_valid_strength,
    max(recorded_at) AS last_response_at,
    coalesce(sum(length(coalesce(note,''))),0) AS total_comment_characters
  FROM public.responses
)
SELECT
  now() AS checked_at,
  (SELECT count(*) FROM public.studies) AS studies,
  (SELECT count(*) FROM public.participants) AS participant_memberships,
  (SELECT count(*) FROM public.assignments) AS total_assignments,
  (SELECT count(*) FROM original) AS original_assignment_rows,
  (SELECT count(*) FROM pair_sides WHERE sides=2 AND people=2) AS complete_original_pairs,
  r.responses_saved,
  r.with_feeling_descriptions,
  r.with_written_comments,
  r.with_valid_strength,
  r.total_comment_characters,
  r.last_response_at,
  (r.with_feeling_descriptions=r.responses_saved
   AND r.with_valid_strength=r.responses_saved
   AND (SELECT count(*) FROM original)=200
   AND (SELECT count(*) FROM pair_sides WHERE sides=2 AND people=2)=100)
    AS core_integrity_checks_pass
FROM resp r;
