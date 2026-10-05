-- Local synthetic transaction/privilege assertions. Roll back all changes.
begin;
truncate secondlook_private.command_receipts, secondlook_private.spaces;
do $$
declare
    owner uuid := '20000000-0000-0000-0000-000000000001';
    peer uuid := '20000000-0000-0000-0000-000000000002';
    outsider uuid := '20000000-0000-0000-0000-000000000003';
    space uuid := '20000000-0000-0000-0000-000000000004';
    command uuid := '20000000-0000-0000-0000-000000000005';
    state jsonb := '{"routines":[],"runs":[],"archives":[]}';
    original jsonb;
    joined jsonb;
    committed jsonb;
    role_name text;
    function_name text;
begin
    foreach role_name in array array['anon','authenticated'] loop
        if has_schema_privilege(role_name, 'secondlook_private', 'usage') then
            raise exception 'private schema exposed';
        end if;
        foreach function_name in array array[
            'public.sl_create(uuid,uuid,uuid,jsonb,text,timestamptz)',
            'public.sl_join(uuid,text)', 'public.sl_read(uuid,uuid)',
            'public.sl_receipt(uuid,uuid,uuid,text)',
            'public.sl_commit(uuid,uuid,bigint,uuid,text,jsonb,uuid)'] loop
            if has_function_privilege(role_name,function_name,'execute') then
                raise exception 'private RPC exposed';
            end if;
        end loop;
    end loop;
    if has_table_privilege('service_role','secondlook_private.spaces','select,insert,update,delete') then
        raise exception 'service direct table access exposed';
    end if;
    original := public.sl_create(owner,peer,space,state,repeat('a',64),clock_timestamp()+interval '10 minutes');
    begin
        perform public.sl_read(peer,null);
        raise exception 'unjoined peer discovery leaked state';
    exception when raise_exception then
        if sqlerrm <> 'notPaired' then raise; end if;
    end;
    begin
        perform public.sl_read(peer,space);
        raise exception 'unjoined peer read explicit state';
    exception when raise_exception then
        if sqlerrm <> 'forbidden' then raise; end if;
    end;
    begin
        perform public.sl_join(owner,repeat('a',64));
        raise exception 'self pairing accepted';
    exception when raise_exception then
        if sqlerrm <> 'invalidInvite' then raise; end if;
    end;
    begin
        perform public.sl_join(outsider,repeat('a',64));
        raise exception 'third pairing accepted';
    exception when raise_exception then
        if sqlerrm <> 'invalidInvite' then raise; end if;
    end;
    update secondlook_private.spaces set invite_expires_at=clock_timestamp()-interval '1 second';
    begin
        perform public.sl_join(peer,repeat('a',64));
        raise exception 'expired invitation accepted';
    exception when raise_exception then
        if sqlerrm <> 'invalidInvite' then raise; end if;
    end;
    if public.sl_create(owner,peer,gen_random_uuid(),state,repeat('b',64),clock_timestamp()+interval '10 minutes') <> original then
        raise exception 'rotation changed shared state';
    end if;
    begin
        perform public.sl_join(peer,repeat('a',64));
        raise exception 'rotated invitation accepted';
    exception when raise_exception then
        if sqlerrm <> 'invalidInvite' then raise; end if;
    end;
    joined := public.sl_join(peer,repeat('b',64));
    if (joined->>'revision')::int <> 1 or jsonb_array_length(joined->'members') <> 2 then
        raise exception 'pairing transaction invalid';
    end if;
    begin
        perform public.sl_join(peer,repeat('b',64));
        raise exception 'replayed invitation accepted';
    exception when raise_exception then
        if sqlerrm <> 'pairingUnavailable' then raise; end if;
    end;
    begin
        perform public.sl_commit(owner,space,0,command,repeat('c',64),state,null);
        raise exception 'stale commit accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    if (select count(*) from secondlook_private.command_receipts) <> 0 then
        raise exception 'failed commit left receipt';
    end if;
    committed := public.sl_commit(owner,space,1,command,repeat('c',64),state,command);
    if (committed->'snapshot'->>'revision')::int <> 2 then raise exception 'commit revision invalid'; end if;
    if public.sl_commit(owner,space,1,command,repeat('c',64),state,command) <> committed then
        raise exception 'duplicate receipt changed result';
    end if;
    begin
        perform public.sl_commit(owner,space,2,command,repeat('d',64),state,null);
        raise exception 'changed request reused receipt';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_receipt(peer,space,command,repeat('c',64));
        raise exception 'other actor borrowed receipt';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_read(outsider,space);
        raise exception 'third account read state';
    exception when raise_exception then
        if sqlerrm <> 'forbidden' then raise; end if;
    end;
    if public.sl_read(owner,space) <> committed->'snapshot' then
        raise exception 'denial changed state';
    end if;
end;
$$;
rollback;
