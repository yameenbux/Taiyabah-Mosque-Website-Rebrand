--  =====================================================================
--  126 - A MESSAGE BELONGS TO A MASJID, LIKE EVERY OTHER TABLE
--  29 September 2026
--  =====================================================================
--
--  db/125 built madrasah_messages exactly as the spec drew it, and the spec's
--  table has no masjid_id (it reaches its masjid through its thread). Reading
--  health_check() afterwards showed a THIRD failing check where slice 1 had
--  left two: `every_table_has_a_masjid` lists any table in public with no
--  masjid_id, and a table added outside the tenancy work is exactly what that
--  check exists to catch. It was right. A row that cannot say which masjid it
--  belongs to is a row the tenancy guard cannot see.
--
--  THE FIX IS THE COLUMN, NOT AN EXEMPTION. (079 exempted the import landing
--  tables because they are not tenanted data; messages are.) The column is
--  filled by a trigger from the thread, and ALWAYS from the thread - a value
--  passed in is overwritten - so no function that inserts a message can
--  forget it, name the wrong masjid, or leave it null, and none of the
--  functions from 125 needed to change.
--
--  NOT NULL is applied after the backfill, so `tenancy_enforced` (which
--  looks for a nullable masjid_id) stays green too.
--
--  TO REMOVE: drop trigger madrasah_messages_masjid on public.madrasah_messages;
--  drop function public.madrasah_messages_set_masjid(); alter table
--  public.madrasah_messages drop column masjid_id;
--  =====================================================================

alter table public.madrasah_messages
  add column if not exists masjid_id uuid references public.masjids(id) on delete cascade;

update public.madrasah_messages m
   set masjid_id = t.masjid_id
  from public.madrasah_threads t
 where t.id = m.thread_id and m.masjid_id is null;

create or replace function public.madrasah_messages_set_masjid()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  select t.masjid_id into new.masjid_id
    from public.madrasah_threads t where t.id = new.thread_id;
  return new;
end $$;
revoke all on function public.madrasah_messages_set_masjid() from public, anon, authenticated;

drop trigger if exists madrasah_messages_masjid on public.madrasah_messages;
create trigger madrasah_messages_masjid
  before insert on public.madrasah_messages
  for each row execute function public.madrasah_messages_set_masjid();

alter table public.madrasah_messages alter column masjid_id set not null;
create index if not exists madrasah_messages_masjid_idx on public.madrasah_messages (masjid_id);

--  ---- THE PROOF (rolled back) -------------------------------------------
do $proof$
declare
  v_m2 uuid; v_hh2 uuid; v_t uuid; v_mid uuid; v_other uuid; v_bad text := '';
begin
  begin
    insert into public.masjids (slug, name, town) values ('zz-proof126', 'ZZ Proof 126', 'Nowhere') returning id into v_m2;
    insert into public.madrasah_households (masjid_id, reference, name) values (v_m2, 'MF-999992', 'Zzzfamily126 proof') returning id into v_hh2;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_m2, v_hh2, 'ZZ-126') returning id into v_t;
    --  the caller names NO masjid, then the WRONG one; either way the thread's wins
    insert into public.madrasah_messages (thread_id, body, from_parent) values (v_t, 'ZZ-A', true);
    select id into v_other from public.masjids where id <> v_m2 order by id limit 1;
    insert into public.madrasah_messages (thread_id, body, from_parent, masjid_id) values (v_t, 'ZZ-B', true, v_other);
    if (select count(*) from public.madrasah_messages where thread_id = v_t and masjid_id = v_m2) <> 2 then
      v_bad := v_bad || 'a message did not take its thread''s masjid; ';
    end if;
    if (select count(*) from public.madrasah_messages where thread_id = v_t and masjid_id = v_other) <> 0 then
      v_bad := v_bad || 'a message kept a masjid it named itself; ';
    end if;
    --  the cascade from the masjid, and from the household, still reaches the messages
    delete from public.madrasah_households where id = v_hh2;
    if exists (select 1 from public.madrasah_messages where thread_id = v_t) then
      v_bad := v_bad || 'deleting the household left a message; ';
    end if;
    --  and the health guard that made this file necessary is now satisfied
    if 'every_table_has_a_masjid' = any (select jsonb_array_elements_text(public.health_check() -> 'failing')) then
      v_bad := v_bad || 'every_table_has_a_masjid still fails; ';
    end if;
    if 'tenancy_enforced' = any (select jsonb_array_elements_text(public.health_check() -> 'failing')) then
      v_bad := v_bad || 'tenancy_enforced fails; ';
    end if;
    if v_bad <> '' then raise exception 'PROOF FAILED: %', v_bad; end if;
    raise exception 'SENTINEL' using errcode = 'P0999';
  exception when sqlstate 'P0999' then null;
  end;
  if exists (select 1 from public.masjids where slug = 'zz-proof126')
     or exists (select 1 from public.madrasah_households where reference = 'MF-999992')
     or exists (select 1 from public.madrasah_threads where subject = 'ZZ-126') then
    raise exception 'PROOF FAILED: something the proof wrote survived it';
  end if;
end $proof$;
