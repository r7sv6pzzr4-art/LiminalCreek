-- LiminalCreek: private shared-study sampling snapshot (READ ONLY)
-- Run ONLY in Supabase SQL Editor; export the single-column result as CSV.
-- This query does not modify any live records and excludes comments,
-- descriptions, participant names, emails, and auth identifiers from output.
-- The resulting coordinates and individual intensity ratings ARE PRIVATE.
-- Never upload the export to any public GitHub repository, Pages, or Actions.
--
-- Identifies the established live study explicitly.
WITH target AS (
  SELECT s.id, s.polygons
  FROM public.studies s
  WHERE s.id = '664b110e-7d5e-445e-815c-986430baf9bd'::uuid
    AND s.started_at IS NOT NULL AND s.revealed_at IS NULL
), members AS (
  SELECT p.study_id, p.user_id,
         CASE row_number() OVER (PARTITION BY p.study_id ORDER BY p.user_id)
           WHEN 1 THEN 'A' ELSE 'B' END AS role
  FROM public.participants p JOIN target t ON t.id=p.study_id
), original AS (
  SELECT a.study_id, a.id AS assignment_id, a.user_id, a.pair_id,
         a.sequence_no, a.longitude, a.latitude, m.role
  FROM public.assignments a JOIN members m
    ON m.study_id=a.study_id AND m.user_id=a.user_id
  WHERE a.sequence_no BETWEEN 1 AND 100
), paired AS (
  SELECT pair_id,
      max(longitude) FILTER (WHERE role='A') AS a_lon,
      max(latitude) FILTER (WHERE role='A') AS a_lat,
      max(longitude) FILTER (WHERE role='B') AS b_lon,
      max(latitude) FILTER (WHERE role='B') AS b_lat,
      count(*) AS sides,
      count(DISTINCT role) AS participant_sides
  FROM original GROUP BY pair_id
), original_json AS (
  SELECT coalesce(jsonb_agg(jsonb_build_object(
     'id', pair_id::text, 'A',jsonb_build_array(a_lon,a_lat),
     'B',jsonb_build_array(b_lon,b_lat)
  ) ORDER BY pair_id), '[]'::jsonb) AS pairs,
  count(*) AS pair_count,
  count(*) FILTER (WHERE sides<>2 OR participant_sides<>2
       OR a_lon IS NULL OR b_lon IS NULL) AS incomplete_pairs
  FROM paired
), completion AS (
  SELECT m.role, count(o.assignment_id) AS assigned,
         count(r.id) AS completed
  FROM members m LEFT JOIN original o
    ON o.study_id=m.study_id AND o.user_id=m.user_id
  LEFT JOIN public.responses r ON r.assignment_id=o.assignment_id
  GROUP BY m.role
), obs AS (
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'point',jsonb_build_array(o.longitude,o.latitude),
    'participant',o.role, 'pairId',o.pair_id::text,
    'valence',r.valence,'strength',r.strength
  ) ORDER BY o.pair_id,o.role), '[]'::jsonb) AS records,
  count(*) AS count
  FROM public.responses r JOIN original o ON o.assignment_id=r.assignment_id
)
SELECT jsonb_build_object(
  'schemaVersion', 1,
  'studyId',(SELECT id::text FROM target),
  'capturedAt',statement_timestamp(),
  'polygons',(SELECT polygons FROM target),
  'participantCount',(SELECT count(*) FROM members),
  'completion',jsonb_build_object(
    'A',(SELECT completed FROM completion WHERE role='A'),
    'B',(SELECT completed FROM completion WHERE role='B')),
  'assignedOriginal',jsonb_build_object(
    'A',(SELECT assigned FROM completion WHERE role='A'),
    'B',(SELECT assigned FROM completion WHERE role='B')),
  'originalPairCount',(SELECT pair_count FROM original_json),
  'incompleteOriginalPairs',(SELECT incomplete_pairs FROM original_json),
  'originalPairs',(SELECT pairs FROM original_json),
  'responseCount',(SELECT count FROM obs),
  'observations',(SELECT records FROM obs)
)::text AS snapshot_json;
