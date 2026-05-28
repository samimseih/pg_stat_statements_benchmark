\set hot random(1, 4500)
\set a random(1, 100)
BEGIN;
WITH ms_:hot AS (SELECT 1) SELECT FROM ms_:hot;
SELECT :a;
SELECT :a + 1;
SELECT :a + 2;
COMMIT;
