\set a random(1, 100000)
BEGIN;
SELECT :a;
\sleep 500 us
SELECT :a;
\sleep 500 us
SELECT :a;
\sleep 500 us
SELECT :a;
\sleep 500 us
SELECT :a;
\sleep 500 us
SELECT :a;
COMMIT;
