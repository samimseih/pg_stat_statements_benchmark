\set roll random(1, 100)
\set hot random(1, 1000)
\set churn random(1, 100000)
\if :roll <= 80
WITH hot:hot AS (SELECT 1) SELECT FROM hot:hot
\else
WITH t:churn AS (SELECT 1) SELECT FROM t:churn
\endif
