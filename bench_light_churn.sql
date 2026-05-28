\set roll random(1, 1000)
\set hot random(1, 1000)
\set cold random(1, 10000)
\if :roll <= 995
WITH hot:hot AS (SELECT 1) SELECT FROM hot:hot
\else
WITH t:cold AS (SELECT 1) SELECT FROM t:cold
\endif
