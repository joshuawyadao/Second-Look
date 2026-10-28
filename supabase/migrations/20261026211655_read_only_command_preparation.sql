-- Read a command's authoritative retry receipt or current snapshot in one
-- service-only round trip. The row lock makes the receipt/snapshot pair coherent;
-- sl_commit still repeats every guard under its exclusive lock.
create function public.sl_prepare(
    p_actor uuid, p_space uuid, p_command_id uuid, p_digest text
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
begin
    select * into current_space
      from secondlook_private.spaces
      where space_id = p_space
      for share;
    if not found then
        raise exception using message = 'notPaired';
    end if;
    if p_actor is null or not (p_actor = any(current_space.members)) then
        raise exception using message = 'forbidden';
    end if;
    if p_command_id is null or p_digest is null
       or p_digest !~ '^[0-9a-f]{64}$' then
        raise exception using message = 'invalidResponse';
    end if;

    select * into saved_receipt
      from secondlook_private.command_receipts
      where space_id = p_space and command_id = p_command_id;
    if found then
        if saved_receipt.actor_id <> p_actor
           or saved_receipt.request_digest <> p_digest then
            raise exception using message = 'staleState';
        end if;
        return pg_catalog.jsonb_build_object('receipt',
            pg_catalog.jsonb_build_object(
                'snapshot', secondlook_private.snapshot(current_space),
                'createdID', saved_receipt.created_id));
    end if;
    return pg_catalog.jsonb_build_object('snapshot', secondlook_private.snapshot(current_space));
end;
$$;

revoke all on function public.sl_prepare(uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.sl_prepare(uuid, uuid, uuid, text)
  to service_role;
