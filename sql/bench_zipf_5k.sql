\set roll random(1, 100)
\set t1 random(1, 10)
\set t2 random(1, 50)
\set t3 random(1, 500)
\set t4 random(1, 10000)
\if :roll <= 50
WITH t1_:t1 AS (SELECT 1) SELECT FROM t1_:t1
\elif :roll <= 80
WITH t2_:t2 AS (SELECT 1) SELECT FROM t2_:t2
\elif :roll <= 95
WITH t3_:t3 AS (SELECT 1) SELECT FROM t3_:t3
\else
WITH t4_:t4 AS (SELECT 1) SELECT FROM t4_:t4
\endif
