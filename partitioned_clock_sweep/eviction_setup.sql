-- Setup: run once before pgbench
-- Requires pg_stat_statements.max = 100

CREATE EXTENSION IF NOT EXISTS injection_points;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Helper function: generates a structurally unique query based on n
-- Uses 2D encoding: cols = (n % 200) + 1, rows = (n / 200) + 1
-- Different col count + different aliased FROM entries = unique parse tree
CREATE OR REPLACE FUNCTION pgss_unique_query(n int) RETURNS void AS $$
DECLARE
  cols int := (n % 200) + 1;
  rows int := (n / 200) + 1;
  col_part text;
  from_parts text[];
BEGIN
  col_part := array_to_string(array_fill(1, ARRAY[cols]), ',');
  FOR i IN 1..rows LOOP
    from_parts := array_append(from_parts,
      format('generate_series(1,1) AS gs%s', i));
  END LOOP;
  EXECUTE format('SELECT %s FROM %s', col_part,
    array_to_string(from_parts, ','));
END;
$$ LANGUAGE plpgsql;

DROP SEQUENCE IF EXISTS eviction_seq;
CREATE SEQUENCE eviction_seq;

SET pg_stat_statements.track = 'all';

SELECT pg_stat_statements_reset();

-- Phase 1: Fill to capacity with 100 unique queries
SELECT pgss_unique_query(g) FROM generate_series(1, 100) g;

SELECT pg_stat_report_anytime(pg_backend_pid());

-- Phase 2: Heat up queries 1-95 to refcount=10
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;
SELECT pgss_unique_query(g) FROM generate_series(1, 95) g;

SELECT pg_stat_report_anytime(pg_backend_pid());

-- Attach injection points
SELECT injection_points_attach('pgss-eviction-created', 'notice');
SELECT injection_points_attach('pgss-eviction-decay', 'notice');
SELECT injection_points_attach('pgss-eviction-evicted', 'notice');
