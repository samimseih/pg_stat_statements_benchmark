\set roll random(1, 500000)
\set hot random(1, 4950)
\set churn random(1, 1000000000)
\if :roll <= 499999
WITH hot_:hot AS (SELECT 1) SELECT FROM hot_:hot
\else
WITH slow_churn_:churn AS (SELECT 1) SELECT FROM slow_churn_:churn
\endif
