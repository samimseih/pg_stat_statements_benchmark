\set id random(1, :residents)
WITH CTEPOP_:id AS MATERIALIZED (SELECT :id::int AS v) SELECT v FROM CTEPOP_:id;
