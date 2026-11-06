-- LiminalCreek LIVE shared-study readiness inventory — READ ONLY
-- Run only in production project fwdsoluixqeycapncecl, before any changes.
-- This returns COUNTS ONLY: no participant identifiers, location coordinates,
-- answers, comments, or hidden study observations.
-- Never run release SQL until this inventory is reviewed and a backup exists.
BEGIN TRANSACTION READ ONLY;
WITH active AS (
 SELECT s.id,s.polygons FROM public.studies s
 WHERE s.started_at IS NOT NULL AND s.revealed_at IS NULL
), roster AS (
 SELECT p.study_id,p.user_id,p.is_admin
 FROM public.participants p JOIN active s ON s.id=p.study_id
), assigned AS (
 SELECT a.id,a.study_id,a.user_id,a.pair_id,a.sequence_no
 FROM public.assignments a JOIN active s ON s.id=a.study_id
), submitted AS (
 SELECT r.id,r.study_id,r.user_id,r.assignment_id
 FROM public.responses r JOIN active s ON s.id=r.study_id
), pair_counts AS (
 SELECT a.pair_id,count(*) rows_per_pair,count(DISTINCT a.user_id) members_per_pair
 FROM assigned a GROUP BY a.pair_id
), progress AS (
 SELECT p.is_admin, count(DISTINCT a.id) total_assigned,
   (SELECT count(*) FROM submitted r WHERE r.user_id=p.user_id) total_completed
 FROM roster p LEFT JOIN assigned a ON a.user_id=p.user_id AND a.study_id=p.study_id
 GROUP BY p.study_id,p.user_id,p.is_admin
), geometry_features AS (
 SELECT CASE WHEN a.polygons->>'type'='FeatureCollection'
         THEN x.value->'geometry'
         WHEN a.polygons->>'type'='Feature'
         THEN a.polygons->'geometry'
         ELSE a.polygons END AS geom
 FROM active a CROSS JOIN LATERAL jsonb_array_elements(
  CASE WHEN a.polygons->>'type'='FeatureCollection'
    THEN a.polygons->'features'
    ELSE jsonb_build_array(a.polygons)
  END) x
), polygon_components AS (
 SELECT y.value AS rings
 FROM geometry_features f CROSS JOIN LATERAL jsonb_array_elements(
   CASE WHEN f.geom->>'type'='Polygon'
     THEN jsonb_build_array(f.geom->'coordinates')
     WHEN f.geom->>'type'='MultiPolygon' THEN f.geom->'coordinates'
     ELSE '[]'::jsonb END
 ) y
)
SELECT
 (SELECT count(*) FROM active)::integer AS active_studies,
 (SELECT count(*) FROM roster)::integer AS participants,
 (SELECT count(*) FROM roster WHERE is_admin)::integer AS administrators,
 (SELECT count(*) FROM assigned)::integer AS assigned_rows,
 (SELECT count(*) FROM assigned WHERE sequence_no BETWEEN 1 AND 100)::integer AS original_assigned_rows,
 (SELECT count(*) FROM pair_counts)::integer AS distinct_pairs,
 (SELECT count(*) FROM pair_counts WHERE rows_per_pair<>2 OR members_per_pair<>2)::integer AS invalid_pairs,
 (SELECT count(*) FROM (
   SELECT a.user_id,a.sequence_no
   FROM assigned a GROUP BY a.user_id,a.sequence_no HAVING count(*)<>1
  ) duplicates)::integer AS duplicate_sequences,
 (SELECT count(*) FROM submitted)::integer AS submitted_responses,
 (SELECT count(*) FROM submitted r
  LEFT JOIN assigned a ON a.id=r.assignment_id
  WHERE a.id IS NULL OR a.user_id<>r.user_id OR a.study_id<>r.study_id
 )::integer AS invalid_response_ownership,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('admin',is_admin,
   'assigned',total_assigned,'completed',total_completed) ORDER BY is_admin DESC),'[]'::jsonb)
  FROM progress) AS progress_by_role,
 (SELECT count(*) FROM polygon_components)::integer AS polygon_parts,
 (SELECT coalesce(sum(greatest(jsonb_array_length(rings)-1,0)),0)
  FROM polygon_components)::integer AS exclusion_rings,
 (to_regclass('public.liminal_auto_batches') IS NOT NULL)
    AS already_has_adaptive_table,
 (to_regprocedure('public.liminal_admin_auto_status()') IS NOT NULL)
    AS already_has_adaptive_status,
 (to_regprocedure('public.liminal_my_progress()') IS NOT NULL)
    AS already_has_own_progress,
 (SELECT count(*)=1 FROM active) AND
 (SELECT count(*)=2 FROM roster) AND
 (SELECT count(*)=1 FROM roster WHERE is_admin) AND
 (SELECT count(*)=200 FROM assigned) AND
 (SELECT count(*)=200 FROM assigned WHERE sequence_no BETWEEN 1 AND 100) AND
 (SELECT count(*)=100 FROM pair_counts) AND
 (SELECT count(*)=0 FROM pair_counts WHERE rows_per_pair<>2 OR members_per_pair<>2) AND
 (SELECT count(*)=0 FROM (
   SELECT a.user_id,a.sequence_no FROM assigned a GROUP BY a.user_id,a.sequence_no
    HAVING count(*)<>1) d) AND
 (SELECT count(*)=0 FROM submitted r LEFT JOIN assigned a ON a.id=r.assignment_id
  WHERE a.id IS NULL OR a.user_id<>r.user_id OR a.study_id<>r.study_id) AND
 (SELECT count(*)>0 FROM polygon_components) AND
 to_regclass('public.liminal_auto_batches') IS NULL
 AS inventory_ready_for_review;
COMMIT;
