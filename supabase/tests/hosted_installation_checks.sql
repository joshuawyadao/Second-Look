-- Read-only hosted M2 catalog checks. No participant data is selected or changed.
-- Run after initial installation. Empty state is expected only before first pairing.
with private_tables as (
  select c.oid, c.relrowsecurity from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'secondlook_private' and c.relkind = 'r'
), command_functions as (
  select p.oid, p.prosecdef, p.proconfig from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in
    ('sl_create', 'sl_join', 'sl_read', 'sl_receipt', 'sl_commit')
), roles as (
  select unnest(array['anon', 'authenticated', 'service_role']) as role_name
)
select 'private_tables_have_rls' as check_name,
  (select count(*) = 2 and bool_and(relrowsecurity) from private_tables) as passed
union all
select 'private_schema_denies_direct_roles',
  (select bool_and(not pg_catalog.has_schema_privilege(role_name, 'secondlook_private', 'USAGE,CREATE')) from roles)
union all
select 'private_tables_deny_direct_roles',
  (select count(*) = 6 and bool_and(not pg_catalog.has_table_privilege(role_name, oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')) from roles cross join private_tables)
union all
select 'commands_use_definer_and_empty_search_path',
  (select count(*) = 5 and bool_and(prosecdef and proconfig @> array['search_path=""']) from command_functions)
union all
select 'commands_allow_only_service_role',
  (select count(*) = 5 and bool_and(
    pg_catalog.has_function_privilege('service_role', oid, 'EXECUTE')
    and not pg_catalog.has_function_privilege('anon', oid, 'EXECUTE')
    and not pg_catalog.has_function_privilege('authenticated', oid, 'EXECUTE')) from command_functions)
union all
select 'internal_functions_deny_direct_roles',
  (select count(*) = 3 and bool_and(not pg_catalog.has_function_privilege(role_name, p.oid, 'EXECUTE'))
   from roles cross join pg_catalog.pg_proc p
   join pg_catalog.pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'secondlook_private')
union all
select 'initial_shared_state_is_empty',
  (select count(*) = 0 from secondlook_private.spaces)
  and (select count(*) = 0 from secondlook_private.command_receipts)
order by check_name;
