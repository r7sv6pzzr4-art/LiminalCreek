#!/usr/bin/env bash
# Synthetic-only regression test. Never uses live Supabase credentials.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
scratch="$(mktemp -d)"
source_db="liminal-synthetic-source-$$"
restored_db="liminal-synthetic-recovered-$$"
cleanup() {
  docker rm -f "$source_db" "$restored_db" >/dev/null 2>&1 || true
  rm -rf "$scratch"
}
trap cleanup EXIT
docker run -d --name "$source_db" \
  -e POSTGRES_PASSWORD=synthetic-only postgres:18 >/dev/null
for i in $(seq 1 45); do
  if docker exec "$source_db" pg_isready -U postgres -q; then break; fi
  sleep 1
done
docker exec -i "$source_db" psql -U postgres -d postgres \
  -q -X -v ON_ERROR_STOP=1 < "$here/scratch-tables.sql"
docker exec -i "$source_db" psql -U postgres -d postgres -q -X \
  -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.studies(id,name,polygons,created_at,started_at)
VALUES ('00000000-0000-4000-8000-000000000001','synthetic',
 '{"type":"FeatureCollection","features":[]}',now(),now());
INSERT INTO public.participants(study_id,user_id,display_name,is_admin) VALUES
 ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','A',true),
 ('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000003','B',false);
INSERT INTO public.assignments(id,study_id,user_id,pair_id,longitude,latitude,
sequence_no,sampling_type,created_at) VALUES
 ('00000000-0000-4000-8000-000000000004','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002','00000000-0000-4000-8000-000000000006',-74.16,40.32,1,'broad',now()),
 ('00000000-0000-4000-8000-000000000005','00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000003','00000000-0000-4000-8000-000000000006',-74.161,40.321,1,'broad',now());
INSERT INTO public.responses(id,assignment_id,study_id,user_id,valence,
descriptions,strength,note,recorded_at) VALUES
 ('00000000-0000-4000-8000-000000000007','00000000-0000-4000-8000-000000000004',
  '00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000002',
  'mixed',ARRAY['Spiritual feeling','Melancholy'],4,
  E'A note with accents: café; and a newline\nplus a tab\t.',now()),
 ('00000000-0000-4000-8000-000000000008','00000000-0000-4000-8000-000000000005',
  '00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000003',
  'neutral',ARRAY['No particular feeling'],NULL,'',now());
SQL
docker exec -i "$source_db" psql -U postgres -d postgres -q -A -t -X \
  -v ON_ERROR_STOP=1 < "$here/internal-health-snapshot.sql" \
  > "$scratch/live-before.json"
docker exec "$source_db" pg_dump -U postgres -d postgres \
  -Fc --schema=public --no-owner -f /tmp/study-public.dump
docker cp "$source_db:/tmp/study-public.dump" "$scratch/study-public.dump"
docker exec -i "$source_db" psql -U postgres -d postgres -q -A -t -X \
  -v ON_ERROR_STOP=1 < "$here/internal-health-snapshot.sql" \
  > "$scratch/live-after.json"

docker run -d --name "$restored_db" \
  -e POSTGRES_PASSWORD=synthetic-only \
  -v "$scratch:/backup:ro" postgres:18 >/dev/null
for i in $(seq 1 45); do
  if docker exec "$restored_db" pg_isready -U postgres -q; then break; fi
  sleep 1
done
docker exec -i "$restored_db" psql -U postgres -d postgres \
  -q -X -v ON_ERROR_STOP=1 < "$here/scratch-tables.sql"
for table in studies participants assignments responses; do
  docker exec "$restored_db" pg_restore -U postgres -d postgres \
    --data-only --no-owner --no-acl --exit-on-error \
    --table="$table" /backup/study-public.dump
done
docker exec -i "$restored_db" psql -U postgres -d postgres \
  -q -A -t -X -v ON_ERROR_STOP=1 \
  < "$here/internal-health-snapshot.sql" \
  > "$scratch/recovered.json"
python3 "$here/compare-snapshots.py" \
  "$scratch/live-before.json" \
  "$scratch/live-after.json" \
  "$scratch/recovered.json"
echo "Synthetic backup and exact written-comment recovery succeeded."
