-- A renewal must be based on the owner's observed revision. Existing installations
-- retain the six-argument RPC, but it can now create only the absent singleton.
create function public.sl_create(
    p_actor uuid,
    p_peer uuid,
    p_space uuid,
    p_state jsonb,
    p_invite_hash text,
    p_expires_at timestamptz,
    p_expected_revision bigint
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    current_space secondlook_private.spaces%rowtype;
    invitation_now timestamptz := pg_catalog.clock_timestamp();
begin
    if p_actor is null or p_peer is null or p_peer = p_actor or p_space is null
       or p_state is null or pg_catalog.jsonb_typeof(p_state) <> 'object'
       or p_invite_hash is null or p_invite_hash !~ '^[0-9a-f]{64}$'
       or p_expires_at is null or p_expires_at <= invitation_now
       or p_expires_at > invitation_now + interval '1 hour'
       or (p_expected_revision is not null and p_expected_revision < 0) then
        raise exception using message = 'invalidResponse';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(38120901, 1);
    select * into current_space
      from secondlook_private.spaces
      where singleton = true
      for update;

    if found then
        if current_space.owner_id <> p_actor
           or pg_catalog.cardinality(current_space.members) <> 1 then
            raise exception using message = 'pairingUnavailable';
        end if;
        if p_expected_revision is null
           or current_space.revision <> p_expected_revision then
            raise exception using message = 'staleState';
        end if;

        -- Leave the aggregate, owner and members intact; only replace the
        -- one-use digest and advance the revision observed by both clients.
        update secondlook_private.spaces
           set invite_hash = p_invite_hash,
               invite_peer = p_peer,
               invite_expires_at = p_expires_at,
               revision = revision + 1
         where singleton = true
         returning * into current_space;
    else
        if p_expected_revision is not null then
            raise exception using message = 'staleState';
        end if;
        insert into secondlook_private.spaces (
            singleton, space_id, owner_id, members, state,
            invite_hash, invite_peer, invite_expires_at
        ) values (
            true, p_space, p_actor, array[p_actor], p_state,
            p_invite_hash, p_peer, p_expires_at
        ) returning * into current_space;
    end if;

    return secondlook_private.snapshot(current_space);
end;
$$;

create or replace function public.sl_create(
    p_actor uuid,
    p_peer uuid,
    p_space uuid,
    p_state jsonb,
    p_invite_hash text,
    p_expires_at timestamptz
)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
    select public.sl_create(p_actor, p_peer, p_space, p_state,
                            p_invite_hash, p_expires_at, null::bigint);
$$;

revoke all on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz, bigint)
    from public, anon, authenticated, service_role;
revoke all on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz)
    from public, anon, authenticated, service_role;
grant execute on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz, bigint)
    to service_role;
grant execute on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz)
    to service_role;

notify pgrst, 'reload schema';
