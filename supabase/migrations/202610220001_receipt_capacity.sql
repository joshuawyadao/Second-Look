-- Bound permanent successful-command receipts without deleting any history.
-- A closed run needs no future receipt; every open run keeps one reserved for
-- cancellation or terminal completion. The space row lock in sl_commit makes
-- this count/admission decision atomic for concurrent command requests.
-- Migration runners execute this file atomically. Hold existing space locks
-- through function replacement; refuse an already-over-cap legacy installation
-- rather than silently enabling a quota without its promised closure reserve.
do $$
declare
    current_space secondlook_private.spaces%rowtype;
    receipt_count bigint;
    open_run_count bigint;
begin
    for current_space in select * from secondlook_private.spaces for update loop
        if pg_catalog.jsonb_typeof(current_space.state->'runs') is distinct from 'array' then
            raise exception using message = 'receiptCapacityUpgradeBlocked';
        end if;
        select pg_catalog.count(*) into receipt_count
          from secondlook_private.command_receipts where space_id = current_space.space_id;
        select pg_catalog.count(*) into open_run_count
          from pg_catalog.jsonb_array_elements(current_space.state->'runs') as run(value)
          where (run.value->>'outcome') is distinct from 'completed'
            and (run.value->>'outcome') is distinct from 'canceled';
        if receipt_count + open_run_count > 8192 then
            raise exception using message = 'receiptCapacityUpgradeBlocked';
        end if;
    end loop;
end;
$$;

create or replace function public.sl_commit(
    p_actor uuid,
    p_space uuid,
    p_expected_revision bigint,
    p_command_id uuid,
    p_digest text,
    p_state jsonb,
    p_created_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    current_space secondlook_private.spaces%rowtype;
    saved_receipt secondlook_private.command_receipts%rowtype;
    receipt_count bigint;
    open_run_count bigint;
begin
    select * into current_space
      from secondlook_private.spaces
      where space_id = p_space
      for update;
    if not found then
        raise exception using message = 'notPaired';
    end if;
    if p_actor is null or not (p_actor = any(current_space.members)) then
        raise exception using message = 'forbidden';
    end if;

    -- Existing successful requests stay replayable at the limit, even if
    -- their supplied state, expected revision or creation ID has changed.
    select * into saved_receipt
      from secondlook_private.command_receipts
      where space_id = p_space and command_id = p_command_id;
    if found then
        if saved_receipt.actor_id <> p_actor
           or saved_receipt.request_digest is distinct from p_digest then
            raise exception using message = 'staleState';
        end if;
        return pg_catalog.jsonb_build_object(
            'snapshot', secondlook_private.snapshot(current_space),
            'createdID', saved_receipt.created_id
        );
    end if;

    if p_command_id is null or p_digest is null
       or p_digest !~ '^[0-9a-f]{64}$'
       or p_state is null or pg_catalog.jsonb_typeof(p_state) <> 'object'
       or p_expected_revision is null or p_expected_revision < 0 then
        raise exception using message = 'invalidResponse';
    end if;
    if current_space.revision <> p_expected_revision then
        raise exception using message = 'staleState';
    end if;
    if pg_catalog.jsonb_typeof(p_state->'runs') is distinct from 'array' then
        raise exception using message = 'invalidResponse';
    end if;

    select pg_catalog.count(*) into receipt_count
      from secondlook_private.command_receipts
      where space_id = p_space;
    -- Swift's optional ChecklistRun.outcome is absent for an open run. JSON
    -- null is treated as open too; only valid terminal values release a
    -- reservation, so an unexpected outcome cannot bypass the bound.
    select pg_catalog.count(*) into open_run_count
      from pg_catalog.jsonb_array_elements(p_state->'runs') as run(value)
      where (run.value->>'outcome') is distinct from 'completed'
        and (run.value->>'outcome') is distinct from 'canceled';
    if receipt_count + 1 + open_run_count > 8192 then
        raise exception using message = 'capacityExceeded';
    end if;

    update secondlook_private.spaces
       set state = p_state, revision = revision + 1
     where singleton = true
     returning * into current_space;

    insert into secondlook_private.command_receipts (
        space_id, command_id, actor_id, request_digest,
        created_id, committed_revision
    ) values (
        p_space, p_command_id, p_actor, p_digest,
        p_created_id, current_space.revision
    );
    return pg_catalog.jsonb_build_object(
        'snapshot', secondlook_private.snapshot(current_space),
        'createdID', p_created_id
    );
end;
$$;

-- CREATE OR REPLACE keeps the existing EXECUTE grants; reassert the exact
-- service-only boundary for this privileged, empty-search-path RPC.
revoke all on function public.sl_commit(uuid, uuid, bigint, uuid, text, jsonb, uuid)
    from public, anon, authenticated, service_role;
grant execute on function public.sl_commit(uuid, uuid, bigint, uuid, text, jsonb, uuid)
    to service_role;
