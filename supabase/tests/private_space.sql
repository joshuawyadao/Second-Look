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
            'public.sl_create(uuid,uuid,uuid,jsonb,text,timestamptz,bigint)',
            'public.sl_join(uuid,text)', 'public.sl_read(uuid,uuid)',
            'public.sl_receipt(uuid,uuid,uuid,text)',
            'public.sl_prepare(uuid,uuid,uuid,text)',
            'public.sl_commit(uuid,uuid,bigint,uuid,text,jsonb,uuid)'] loop
            if has_function_privilege(role_name,function_name,'execute') then
                raise exception 'private RPC exposed';
            end if;
        end loop;
    end loop;
    if has_table_privilege('service_role','secondlook_private.spaces','select,insert,update,delete') then
        raise exception 'service direct table access exposed';
    end if;
    if not has_function_privilege('service_role',
        'public.sl_prepare(uuid,uuid,uuid,text)','execute') then
        raise exception 'server preparation RPC privilege missing';
    end if;
    if not has_function_privilege('service_role',
        'public.sl_create(uuid,uuid,uuid,jsonb,text,timestamptz,bigint)','execute')
       or not has_function_privilege('service_role',
        'public.sl_create(uuid,uuid,uuid,jsonb,text,timestamptz)','execute') then
        raise exception 'server invitation RPC privilege missing';
    end if;
    begin
        perform public.sl_create(owner,peer,space,state,repeat('a',64),
                                 clock_timestamp()+interval '10 minutes',0);
        raise exception 'creation with a revision accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    original := public.sl_create(owner,peer,space,state,repeat('a',64),
                                 clock_timestamp()+interval '10 minutes',null);
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
    begin
        perform public.sl_create(owner,peer,gen_random_uuid(),state,repeat('b',64),
                                 clock_timestamp()+interval '10 minutes');
        raise exception 'legacy renewal without revision accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_create(owner,peer,gen_random_uuid(),state,repeat('b',64),
                                 clock_timestamp()+interval '10 minutes',null);
        raise exception 'renewal without revision accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    if (select invite_hash from secondlook_private.spaces) <> repeat('a',64) then
        raise exception 'rejected renewal changed invitation';
    end if;
    if (public.sl_create(owner,peer,gen_random_uuid(),state,repeat('b',64),
                         clock_timestamp()+interval '10 minutes',0) - 'revision')
       <> (original - 'revision') then
        raise exception 'rotation changed shared identity or state';
    end if;
    if (select revision from secondlook_private.spaces) <> 1 then
        raise exception 'renewal failed to advance revision';
    end if;
    begin
        perform public.sl_create(owner,peer,gen_random_uuid(),state,repeat('c',64),
                                 clock_timestamp()+interval '10 minutes',0);
        raise exception 'stale competing renewal accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    if (select invite_hash from secondlook_private.spaces) <> repeat('b',64) then
        raise exception 'stale renewal displaced winner';
    end if;
    begin
        perform public.sl_join(peer,repeat('a',64));
        raise exception 'rotated invitation accepted';
    exception when raise_exception then
        if sqlerrm <> 'invalidInvite' then raise; end if;
    end;
    joined := public.sl_join(peer,repeat('b',64));
    if (joined->>'revision')::int <> 2 or jsonb_array_length(joined->'members') <> 2 then
        raise exception 'pairing transaction invalid';
    end if;
    if public.sl_prepare(owner,space,command,repeat('c',64))
       <> pg_catalog.jsonb_build_object('snapshot', joined) then
        raise exception 'preparation did not return the current snapshot';
    end if;
    if (select count(*) from secondlook_private.command_receipts) <> 0 then
        raise exception 'preparation wrote a receipt';
    end if;
    begin
        perform public.sl_join(peer,repeat('b',64));
        raise exception 'replayed invitation accepted';
    exception when raise_exception then
        if sqlerrm <> 'pairingUnavailable' then raise; end if;
    end;
    begin
        perform public.sl_commit(owner,space,1,command,repeat('c',64),state,null);
        raise exception 'stale commit accepted';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    if (select count(*) from secondlook_private.command_receipts) <> 0 then
        raise exception 'failed commit left receipt';
    end if;
    committed := public.sl_commit(owner,space,2,command,repeat('c',64),state,command);
    if public.sl_prepare(owner,space,command,repeat('c',64))
       <> pg_catalog.jsonb_build_object('receipt', committed) then
        raise exception 'preparation did not preserve the bound receipt';
    end if;
    if (committed->'snapshot'->>'revision')::int <> 3 then raise exception 'commit revision invalid'; end if;
    if public.sl_commit(owner,space,2,command,repeat('c',64),state,command) <> committed then
        raise exception 'duplicate receipt changed result';
    end if;
    if public.sl_commit(owner,space,2,command,repeat('c',64),'{"forged":true}'::jsonb,outsider) <> committed then
        raise exception 'duplicate receipt accepted replacement creation identity or state';
    end if;
    if committed->>'createdID' is distinct from command::text
       or public.sl_receipt(owner,space,command,repeat('c',64)) is distinct from committed
       or public.sl_read(owner,space) is distinct from committed->'snapshot'
       or (select count(*) from secondlook_private.command_receipts) <> 1 then
        raise exception 'original receipt identity or atomic state was not preserved';
    end if;
    begin
        perform public.sl_commit(owner,space,3,command,repeat('d',64),state,null);
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
        perform public.sl_prepare(peer,space,command,repeat('c',64));
        raise exception 'other actor prepared a receipt';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_prepare(owner,space,command,repeat('d',64));
        raise exception 'changed request prepared a receipt';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_read(outsider,space);
        raise exception 'third account read state';
    exception when raise_exception then
        if sqlerrm <> 'forbidden' then raise; end if;
    end;
    begin
        perform public.sl_prepare(outsider,space,gen_random_uuid(),repeat('c',64));
        raise exception 'third account prepared private state';
    exception when raise_exception then
        if sqlerrm <> 'forbidden' then raise; end if;
    end;
    if public.sl_read(owner,space) <> committed->'snapshot' then
        raise exception 'denial changed state';
    end if;
end;
$$;

-- The receipt cap is checked after the original receipt lookup and before the
-- aggregate update. These are synthetic metadata rows inside this transaction;
-- the final ROLLBACK keeps all other local integration fixtures untouched.
truncate secondlook_private.command_receipts, secondlook_private.spaces;
do $$
declare
    owner uuid := '30000000-0000-0000-0000-000000000001';
    peer uuid := '30000000-0000-0000-0000-000000000002';
    outsider uuid := '30000000-0000-0000-0000-000000000003';
    space uuid := '30000000-0000-0000-0000-000000000004';
    admitted uuid := '30000000-0000-0000-0000-000000000005';
    rejected uuid := '30000000-0000-0000-0000-000000000006';
    closure uuid := '30000000-0000-0000-0000-000000000007';
    final_closure uuid := '30000000-0000-0000-0000-000000000009';
    digest text := repeat('d',64);
    -- Codable omits a nil outcome on an open run and includes a string on a
    -- closed one. Other run fields are immaterial to this SQL admission check.
    open_state jsonb := '{"routines":[],"runs":[{"id":"30000000-0000-0000-0000-000000000008"},{"id":"30000000-0000-0000-0000-00000000000a"}],"archives":[]}';
    one_closed_state jsonb := '{"routines":[],"runs":[{"id":"30000000-0000-0000-0000-000000000008","outcome":"canceled"},{"id":"30000000-0000-0000-0000-00000000000a"}],"archives":[]}';
    closed_state jsonb := '{"routines":[],"runs":[{"id":"30000000-0000-0000-0000-000000000008","outcome":"canceled"},{"id":"30000000-0000-0000-0000-00000000000a","outcome":"completed"}],"archives":[]}';
    first_result jsonb;
    close_result jsonb;
begin
    if not has_function_privilege('service_role',
        'public.sl_commit(uuid,uuid,bigint,uuid,text,jsonb,uuid)','execute')
       or has_function_privilege('authenticated',
        'public.sl_commit(uuid,uuid,bigint,uuid,text,jsonb,uuid)','execute') then
        raise exception 'receipt-cap migration changed RPC privileges';
    end if;
    insert into secondlook_private.spaces
        (space_id,owner_id,members,revision,state)
        values (space,owner,array[owner,peer],8189,open_state);
    insert into secondlook_private.command_receipts
        (space_id,command_id,actor_id,request_digest,committed_revision)
        select space,
               ('00000000-0000-0000-0000-' || lpad(to_hex(n),12,'0'))::uuid,
               owner,digest,n
          from generate_series(1,8189) as n;

    first_result := public.sl_commit(owner,space,8189,admitted,digest,open_state,admitted);
    if (first_result->'snapshot'->>'revision')::bigint <> 8190
       or first_result->>'createdID' is distinct from admitted::text
       or (select count(*) from secondlook_private.command_receipts) <> 8190 then
        raise exception 'final nonterminal receipt admission failed';
    end if;

    begin
        perform public.sl_commit(owner,space,8190,rejected,digest,open_state,null);
        raise exception 'nonterminal write consumed closure reserve';
    exception when raise_exception then
        if sqlerrm <> 'capacityExceeded' then raise; end if;
    end;
    if (select revision from secondlook_private.spaces) <> 8190
       or (select state from secondlook_private.spaces) <> open_state
       or (select count(*) from secondlook_private.command_receipts) <> 8190 then
        raise exception 'capacity refusal changed state, revision or receipts';
    end if;
    if public.sl_commit(owner,space,0,admitted,digest,'{"forged":true}'::jsonb,outsider)
       <> first_result
       or public.sl_receipt(owner,space,admitted,digest) <> first_result then
        raise exception 'original actor-bound receipt did not replay at capacity';
    end if;
    begin
        perform public.sl_commit(peer,space,8190,admitted,digest,open_state,null);
        raise exception 'other member borrowed a receipt at capacity';
    exception when raise_exception then
        if sqlerrm <> 'staleState' then raise; end if;
    end;
    begin
        perform public.sl_commit(outsider,space,8190,rejected,digest,open_state,null);
        raise exception 'outsider bypassed membership at capacity';
    exception when raise_exception then
        if sqlerrm <> 'forbidden' then raise; end if;
    end;
    begin
        perform public.sl_commit(owner,space,8190,rejected,'short',open_state,null);
        raise exception 'malformed digest was treated as capacity';
    exception when raise_exception then
        if sqlerrm <> 'invalidResponse' then raise; end if;
    end;
    begin
        perform public.sl_commit(owner,space,8190,rejected,digest,'{"runs":{}}'::jsonb,null);
        raise exception 'malformed run collection bypassed reservation';
    exception when raise_exception then
        if sqlerrm <> 'invalidResponse' then raise; end if;
    end;

    close_result := public.sl_commit(peer,space,8190,closure,digest,one_closed_state,null);
    if (close_result->'snapshot'->>'revision')::bigint <> 8191
       or (select count(*) from secondlook_private.command_receipts) <> 8191
       or (select state from secondlook_private.spaces) <> one_closed_state then
        raise exception 'first terminal closure failed to use its reserved receipt';
    end if;
    if public.sl_prepare(owner,space,admitted,digest)->'receipt'->>'createdID'
       is distinct from admitted::text
       or (public.sl_prepare(owner,space,admitted,digest)->'receipt'->'snapshot'->>'revision')::bigint
          <> 8191 then
        raise exception 'preparation lost original creation identity after newer state';
    end if;
    if public.sl_commit(peer,space,1,closure,digest,'{"forged":true}'::jsonb,outsider)
       <> close_result then
        raise exception 'first terminal receipt was not replayable with reserve full';
    end if;
    close_result := public.sl_commit(owner,space,8191,final_closure,digest,closed_state,null);
    if (close_result->'snapshot'->>'revision')::bigint <> 8192
       or (select count(*) from secondlook_private.command_receipts) <> 8192
       or (select state from secondlook_private.spaces) <> closed_state then
        raise exception 'second terminal closure failed to use its reserved receipt';
    end if;
    if public.sl_commit(owner,space,1,final_closure,digest,'{"forged":true}'::jsonb,outsider)
       <> close_result then
        raise exception 'terminal receipt was not replayable at the hard cap';
    end if;
    begin
        perform public.sl_commit(owner,space,8192,rejected,digest,closed_state,null);
        raise exception 'receipt table exceeded hard cap';
    exception when raise_exception then
        if sqlerrm <> 'capacityExceeded' then raise; end if;
    end;
    if (select revision from secondlook_private.spaces) <> 8192
       or (select count(*) from secondlook_private.command_receipts) <> 8192 then
        raise exception 'hard-cap rejection changed aggregate or receipts';
    end if;
end;
$$;
rollback;
