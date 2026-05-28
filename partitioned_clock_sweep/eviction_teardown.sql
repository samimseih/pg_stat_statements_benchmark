-- Teardown: run after pgbench
SELECT injection_points_detach('pgss-eviction-created');
SELECT injection_points_detach('pgss-eviction-decay');
SELECT injection_points_detach('pgss-eviction-evicted');
