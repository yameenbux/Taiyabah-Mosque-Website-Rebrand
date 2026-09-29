--  =====================================================================
--  095 - WHEN A REGISTER IS DUE
--  =====================================================================
--  Until now nothing could answer "was a register missed", because
--  nothing knew which evenings a class runs. madrasah_classes has no
--  days. What the masjid DOES have is an academic year, eight closures,
--  and - decided 28 September - one setting for which weekdays the
--  madrasah runs. One fact, kept once, rather than 70 copies of it on 70
--  classes that would drift apart within a term.

create table if not exists public.madrasah_settings (
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by uuid references auth.users(id),
  primary key (masjid_id, key)
);
alter table public.madrasah_settings enable row level security;
revoke all on public.madrasah_settings from anon, authenticated;

--  FAILS CLOSED. No setting means NO register is due, never every day.
--  A missing row that made the system chase 70 classes every Sunday
--  would teach everybody to ignore it inside a week.
create or replace function public.register_days()
returns text[] language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(value))
       from public.madrasah_settings
      where masjid_id = public.current_masjid() and key = 'register_days'),
    '{}'::text[]);
$$;

create or replace function public.set_register_days(p_days text[])
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_bad text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may '
                    'change when the madrasah runs.' using errcode = '42501';
  end if;
  select d into v_bad from unnest(p_days) d
   where d not in ('mon','tue','wed','thu','fri','sat','sun') limit 1;
  if v_bad is not null then
    raise exception '% is not a day.', v_bad using errcode = '22023';
  end if;
  insert into public.madrasah_settings (masjid_id, key, value, changed_by)
  values (public.current_masjid(), 'register_days', to_jsonb(p_days), auth.uid())
  on conflict (masjid_id, key) do update
    set value = excluded.value, changed_at = now(), changed_by = excluded.changed_by;
  return jsonb_build_object('days', p_days);
end $$;

create or replace function public.register_due(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_days text[] := public.register_days();
  v_dow text := lower(to_char(p_date, 'Dy'));
  v_closure text;
begin
  if array_length(v_days, 1) is null then
    return jsonb_build_object('due', false,
      'why', 'Nobody has said which evenings the madrasah runs yet.');
  end if;
  if not exists (select 1 from public.madrasah_years y
                  where y.masjid_id = v_masjid and y.is_current
                    and p_date between y.starts_on and y.ends_on) then
    return jsonb_build_object('due', false,
      'why', 'That date is outside the academic year.');
  end if;
  if not (v_dow = any(v_days)) then
    return jsonb_build_object('due', false,
      'why', 'The madrasah does not run on a ' || to_char(p_date, 'Day') || '.');
  end if;
  --  INCLUSIVE AT BOTH ENDS, which is how madrasah_closures is written.
  select c.name into v_closure from public.madrasah_closures c
   where c.masjid_id = v_masjid and p_date between c.starts_on and c.ends_on
   limit 1;
  if v_closure is not null then
    return jsonb_build_object('due', false, 'why', v_closure || '.');
  end if;
  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid and c.is_active
                    and exists (select 1 from public.madrasah_pupil_classes pc
                                  join public.madrasah_pupils p on p.id = pc.pupil_id
                                 where pc.class_id = c.id and p.left_on is null
                                   and p.status = 'on_roll')) then
    return jsonb_build_object('due', false,
      'why', 'That class is not running, or has nobody on its roll.');
  end if;
  return jsonb_build_object('due', true, 'why', '');
end $$;

revoke all on function public.register_days() from public, anon;
revoke all on function public.register_due(uuid, date) from public, anon;
revoke all on function public.set_register_days(text[]) from public, anon;
grant execute on function public.register_days() to authenticated;
grant execute on function public.register_due(uuid, date) to authenticated;
grant execute on function public.set_register_days(text[]) to authenticated;
