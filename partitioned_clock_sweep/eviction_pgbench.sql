-- pgbench custom script: 80% hot re-execution, 20% new trickle
-- Random 1-10: values 1-8 = re-heat a hot query, 9-10 = trickle new
SET pg_stat_statements.track = 'all';
\set roll random(1, 10)
\if :roll <= 8
  \set hot random(1, 95)
  SELECT pgss_unique_query(:hot);
\else
  SELECT pgss_unique_query(nextval('eviction_seq')::int + 200);
\endif
