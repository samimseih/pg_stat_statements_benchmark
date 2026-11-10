\set r random(1, 100)
\if :r <= 90
\set id random(1, 4000)
WITH CTEPOP_:id AS MATERIALIZED (SELECT :id::int AS v) SELECT v FROM CTEPOP_:id;
\else
\set id random(1, 100000000)
WITH CTEUNPOP_:id AS MATERIALIZED (SELECT :id::int AS v) SELECT v FROM CTEUNPOP_:id;
\endif
