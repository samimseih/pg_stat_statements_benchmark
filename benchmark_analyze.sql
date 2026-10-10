\pset footer off

\echo activity wait sample
select count(*) as active_backends,
       coalesce(wait_event_type, '') as wait_event_type,
       coalesce(wait_event, '') as wait_event
from pg_stat_activity
where state = 'active'
group by wait_event_type, wait_event
order by active_backends desc, wait_event_type, wait_event;

\echo backend count
select count(*) as backends
from pg_stat_activity;

\echo pg_stat_statements_info
select *
from pg_stat_statements_info;

\echo pg_stat_statements summary
select count(*) as entries,
       coalesce(sum(calls), 0) as calls,
       count(*) filter (where query is null) as null_query_entries
from pg_stat_statements;

\echo pg_stat_statements retention buckets
select bucket,
       count(*) as entries,
       coalesce(sum(calls), 0) as calls,
       min(calls) as min_calls,
       max(calls) as max_calls,
       avg(calls)::numeric(20,2) as avg_calls
from (
    select case
             when query is null then 'null_query'
             when query like 'WITH CTEPOP_%' then 'pop'
             when query like 'WITH CTEUNPOP_%' then 'unpop'
             when lower(query) like 'select abalance from pgbench_accounts%' then 'select_only'
             else 'other'
           end as bucket,
           calls
    from pg_stat_statements(true)
) s
group by bucket
order by bucket;

\echo hot/cold retention
select
    case
      when query like 'WITH CTEPOP_%' then 'pop'
      when query like 'WITH CTEUNPOP_%' then 'unpop'
    end as bucket,
    count(*) entries,
    coalesce(sum(calls), 0) calls,
    min(calls) min_calls,
    max(calls) max_calls,
    avg(calls)::numeric(20,2) avg_calls
from pg_stat_statements(true)
where query like 'WITH CTEPOP_%'
   or query like 'WITH CTEUNPOP_%'
group by 1
order by 1;
