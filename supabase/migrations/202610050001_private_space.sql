-- Milestone 2: one private space, with all writes mediated by the Swift server.
-- The public RPCs accept an actor only from that server. Its service credential
-- must never be distributed to an iPhone or used as a client authorization rule.

create schema secondlook_private;

create table secondlook_private.spaces (
    singleton boolean primary key default true check (singleton),
    space_id uuid not null unique,
    owner_id uuid not null,
    members uuid[] not null,
    revision bigint not null default 0 check (revision >= 0),
    state jsonb not null check (pg_catalog.jsonb_typeof(state) = 'object'),
    invite_hash text,
    invite_peer uuid,
    invite_expires_at timestamptz,
    constraint space_members_valid check (
        pg_catalog.cardinality(members) between 1 and 2
        and members[1] is not null
        and members[1] = owner_id
        and (pg_catalog.cardinality(members) = 1
             or (members[2] is not null and members[2] <> owner_id))
    ),
    constraint invitation_valid check (
        (invite_hash is null and invite_peer is null and invite_expires_at is null)
        or (invite_hash is not null and invite_peer is not null
            and invite_peer <> owner_id and invite_expires_at is not null
            and pg_catalog.cardinality(members) = 1)
    )
);

create table secondlook_private.command_receipts (
    space_id uuid not null references secondlook_private.spaces(space_id) on delete restrict,
    command_id uuid not null,
    actor_id uuid not null,
    request_digest text not null,
    created_id uuid,
    committed_revision bigint not null check (committed_revision > 0),
    committed_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (space_id, command_id),
    constraint request_digest_sha256 check (request_digest ~ '^[0-9a-f]{64}$')
);

-- No direct PostgREST table role may read or write this aggregate, including
-- service_role. The definer RPCs execute with the migration owner's privileges.
alter table secondlook_private.spaces enable row level security;
alter table secondlook_private.command_receipts enable row level security;
revoke all on schema secondlook_private from public, anon, authenticated, service_role;
revoke all on all tables in schema secondlook_private from public, anon, authenticated, service_role;

create function secondlook_private.snapshot(p_space secondlook_private.spaces)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select pg_catalog.jsonb_build_object(
        'schemaVersion', 1,
        'spaceID', p_space.space_id,
        'revision', p_space.revision,
        'members', pg_catalog.to_jsonb(p_space.members),
        'state', p_space.state
    );
$$;

-- The advisory transaction lock serializes the absent-row create race. Once a
-- row exists, FOR UPDATE serializes invitation rotation with joining.
create function public.sl_create(
    p_actor uuid,
    p_peer uuid,
    p_space uuid,
    p_state jsonb,
    p_invite_hash text,
    p_expires_at timestamptz
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
       or p_expires_at > invitation_now + interval '1 hour' then
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

        -- A repeated create rotates the unconsumed invitation. It does not
        -- reset a run, change the owner, or replace the persistent space ID.
        update secondlook_private.spaces
           set invite_hash = p_invite_hash,
               invite_peer = p_peer,
               invite_expires_at = p_expires_at
         where singleton = true
         returning * into current_space;
    else
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

create function public.sl_join(p_actor uuid, p_invite_hash text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
    current_space secondlook_private.spaces%rowtype;
begin
    if p_actor is null or p_invite_hash is null
       or p_invite_hash !~ '^[0-9a-f]{64}$' then
        raise exception using message = 'invalidInvite';
    end if;

    select * into current_space
      from secondlook_private.spaces
      where singleton = true
      for update;
    if not found then
        raise exception using message = 'invalidInvite';
    end if;
    if pg_catalog.cardinality(current_space.members) <> 1 then
        raise exception using message = 'pairingUnavailable';
    end if;
    if p_actor = current_space.owner_id
       or current_space.invite_hash is null
       or current_space.invite_expires_at is null
       or p_actor is distinct from current_space.invite_peer
       or p_invite_hash is distinct from current_space.invite_hash
       or current_space.invite_expires_at <= pg_catalog.clock_timestamp() then
        raise exception using message = 'invalidInvite';
    end if;

    update secondlook_private.spaces
       set members = array[owner_id, p_actor],
           revision = revision + 1,
           invite_hash = null,
           invite_peer = null,
           invite_expires_at = null
     where singleton = true
     returning * into current_space;
    return secondlook_private.snapshot(current_space);
end;
$$;

create function public.sl_read(p_actor uuid, p_space uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    current_space secondlook_private.spaces%rowtype;
begin
    if p_actor is null then
        raise exception using message = 'forbidden';
    end if;
    select * into current_space
      from secondlook_private.spaces
      where singleton = true and (p_space is null or space_id = p_space);
    if not found then
        raise exception using message = 'notPaired';
    end if;
    if not (p_actor = any(current_space.members)) then
        -- Current-space discovery must leave the verified, allowlisted peer signed in
        -- so they can enter an invitation. It returns no private content.
        if p_space is null then
            raise exception using message = 'notPaired';
        end if;
        raise exception using message = 'forbidden';
    end if;
    return secondlook_private.snapshot(current_space);
end;
$$;

-- A receipt is read before Swift applies a command. A successful retry gets
-- the current state and original created ID; a changed actor/body cannot
-- borrow the old command ID. The commit RPC repeats this check under lock.
create function public.sl_receipt(
    p_actor uuid,
    p_space uuid,
    p_command_id uuid,
    p_digest text
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
    if not found then
        return null;
    end if;
    if saved_receipt.actor_id <> p_actor
       or saved_receipt.request_digest <> p_digest then
        raise exception using message = 'staleState';
    end if;
    return pg_catalog.jsonb_build_object(
        'snapshot', secondlook_private.snapshot(current_space),
        'createdID', saved_receipt.created_id
    );
end;
$$;

-- Compare-and-swap and receipt insertion form one PostgreSQL transaction.
-- The Swift server validates core rules and computes the resulting p_state; only
-- this privileged RPC may install it. This is not a client state-upload API.
create function public.sl_commit(
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

-- PostgreSQL grants EXECUTE to PUBLIC by default for new functions. Remove
-- that grant before this migration commits; PostgREST exposes only these
-- functions to the server's service_role. Its secret stays on that server.
revoke all on all functions in schema secondlook_private
    from public, anon, authenticated, service_role;
revoke all on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz)
    from public, anon, authenticated, service_role;
revoke all on function public.sl_join(uuid, text)
    from public, anon, authenticated, service_role;
revoke all on function public.sl_read(uuid, uuid)
    from public, anon, authenticated, service_role;
revoke all on function public.sl_receipt(uuid, uuid, uuid, text)
    from public, anon, authenticated, service_role;
revoke all on function public.sl_commit(uuid, uuid, bigint, uuid, text, jsonb, uuid)
    from public, anon, authenticated, service_role;

grant execute on function public.sl_create(uuid, uuid, uuid, jsonb, text, timestamptz)
    to service_role;
grant execute on function public.sl_join(uuid, text)
    to service_role;
grant execute on function public.sl_read(uuid, uuid)
    to service_role;
grant execute on function public.sl_receipt(uuid, uuid, uuid, text)
    to service_role;
grant execute on function public.sl_commit(uuid, uuid, bigint, uuid, text, jsonb, uuid)
    to service_role;
