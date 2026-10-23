-- Internal, read-only backup verification query.
-- Executed only in the production DB and in a disposable local recovery DB.
-- Output includes only aggregate counts and row digests, never response text.
WITH rr AS (
 SELECT
   count(*)::bigint AS rows,
   count(*) FILTER (WHERE cardinality(descriptions)>0)::bigint AS descriptions_present,
   count(*) FILTER (WHERE length(btrim(coalesce(note,'')))>0)::bigint AS notes_present,
   coalesce(sum(length(coalesce(note,''))),0)::bigint AS note_characters,
   md5(coalesce(string_agg(md5(row_to_json(r)::text),'' ORDER BY r.id),''))
     AS digest
 FROM public.responses r
), aa AS (
 SELECT count(*)::bigint AS rows,
   md5(coalesce(string_agg(md5(row_to_json(a)::text),'' ORDER BY a.id),''))
     AS digest
 FROM public.assignments a
), ss AS (
 SELECT count(*)::bigint AS rows,
   md5(coalesce(string_agg(md5(row_to_json(s)::text),'' ORDER BY s.id),''))
     AS digest
 FROM public.studies s
), pp AS (
 SELECT count(*)::bigint AS rows,
   md5(coalesce(string_agg(md5(row_to_json(p)::text),''
     ORDER BY p.study_id,p.user_id),''))
     AS digest
 FROM public.participants p
)
SELECT json_build_object(
  'responses',row_to_json(rr),
  'assignments',row_to_json(aa),
  'studies',row_to_json(ss),
  'participants',row_to_json(pp)
)::text FROM rr,aa,ss,pp;
