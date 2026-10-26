-- Operator-only, read-only capacity observations. Returns no task, account or space values.
-- Run against the intended database with an administrative read-capable connection.
-- These sizes are database measurements, not provider dashboard billing or HTTP bytes.
begin read only;
set local statement_timeout = '5s';
set local lock_timeout = '2s';
select pg_database_size(current_database()) as database_bytes,
       count(*) as space_count,
       coalesce(max(octet_length(state::text)), 0) as largest_state_json_text_bytes,
       coalesce(max(pg_column_size(state)), 0) as largest_state_stored_bytes,
       coalesce(max(jsonb_array_length(state->'routines')), 0) as largest_routine_count,
       coalesce(max(jsonb_array_length(state->'runs')), 0) as largest_run_count,
       coalesce(max(jsonb_array_length(state->'archives')), 0) as largest_archive_count,
       (select count(*) from secondlook_private.command_receipts) as receipt_count,
       pg_total_relation_size('secondlook_private.spaces') as spaces_relation_bytes,
       pg_total_relation_size('secondlook_private.command_receipts') as receipts_relation_bytes
from secondlook_private.spaces;
commit;
