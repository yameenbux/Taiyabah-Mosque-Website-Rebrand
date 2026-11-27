-- ===========================================================================
--  177_vacancy_postings.sql — admins post a real vacancy; applicants apply
--  to it properly
--
--  176 built a list for the office to work from once a role is actually
--  advertised. This is that moment: the committee can now write a position
--  up and put it live on the Vacancies page themselves, from the admin
--  portal, without anybody touching this file again — the same shape as
--  db/043's courses (create → write its page → open it) and db/047's "what
--  the website says" pattern (page jsonb, a check_*_page() validator, no
--  source of truth outside the database).
--
--  A posted vacancy gets its OWN application: name, email, phone, a real
--  postal address, date of birth, a CV, and a mandatory membership question
--  — "only a member, or an immediate family member of one, may apply" is the
--  trustees' own instruction, not a lesser version of the 176 interest form.
--  That question is added to BOTH forms, because it is asked by the same
--  trustees of the same roles — a person who registers interest through 176
--  and a person who applies to an open posting through this file are being
--  asked to do the same thing for the same reason.
--
--  NO CAPTCHA. The honeypot, the two-second trap and rate_limit_by_contact()
--  are the same three this site already uses everywhere else a stranger can
--  write to this database — see db/036's header for why a fourth layer is
--  not reached for first. What is new and IS tighter here: a CV is a file,
--  so vacancy_cv_upload_allowed() below caps it at five an hour, where
--  bmcc_upload_allowed() (the nearest precedent, db/059) allows ten.
--
--  NO DELETE, same as courses: closing a vacancy is the reversible thing.
--  save_vacancy() can be called again to edit one; nothing here removes a
--  row.
--
--  Prerequisites: 011 (verified_admin), 037 (rate_limit_by_contact), 043
--  (current_masjid, masjid_id_for), 140 (notify_the_office), 176 (the table
--  this extends, masjid_or_sole, the reference sequence). Idempotent — safe
--  to run twice.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.verified_admin()') is null then
    raise exception 'public.verified_admin() does not exist. Run 011_require_two_step.sql first.';
  end if;
  if to_regclass('public.vacancy_applications') is null then
    raise exception 'public.vacancy_applications does not exist. Run 176_vacancy_applications.sql first.';
  end if;
  if to_regprocedure('public.current_masjid()') is null
     or to_regprocedure('public.masjid_id_for(text)') is null
     or to_regprocedure('public.masjid_or_sole(text)') is null
     or to_regprocedure('public.sole_masjid()') is null then
    raise exception 'The multi-masjid helpers do not exist. Run the masjid-platform migrations first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  1. The vacancies themselves
-- ---------------------------------------------------------------------------
create table if not exists public.vacancies (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid        not null references public.masjids(id),
  key         text        not null,
  category    text        not null,
  title       text        not null,
  summary     text        not null,

  --  Everything else the public page shows — responsibilities, what the
  --  role is looking for, the time it takes, when it closes — lives here,
  --  the same reason it lives in courses.page: it is wording the committee
  --  will want to change far more often than the shape of the table, and a
  --  jsonb column with its own validator (check_vacancy_page below) lets
  --  them without a migration each time. See db/047's header for the fuller
  --  case for this shape.
  page        jsonb       not null default '{}'::jsonb,

  is_open     boolean     not null default true,
  sort_order  int         not null default 0,
  created_by  uuid,
  created_at  timestamptz not null default now(),

  unique (masjid_id, key)
);

do $$
begin
  --  THE SAME FOUR AREAS THE PAGE HAS ALWAYS SHOWN. A posted vacancy fills
  --  in one of the tiles 176 already fixed the interest form's category
  --  to — it does not invent a fifth tile the public page has never had.
  if not exists (select 1 from pg_constraint where conname = 'vac_category_known') then
    alter table public.vacancies add constraint vac_category_known
      check (category in ('administration', 'education', 'community_outreach',
                           'event_management'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'vac_key_shape') then
    alter table public.vacancies add constraint vac_key_shape
      check (key ~ '^[a-z0-9_]{2,40}$');
  end if;
end $$;

create index if not exists vac_masjid_idx on public.vacancies (masjid_id);
create index if not exists vac_open_idx   on public.vacancies (masjid_id, is_open);

comment on table public.vacancies is
  'Positions the committee has actually posted to the Vacancies page. A category with no open row here still shows as "Coming soon" — see vacancies_public().';

alter table public.vacancies enable row level security;

--  No policy, on purpose — same as courses. Nobody reads or writes this
--  table directly; vacancies_public()/vacancies_admin_list()/save_vacancy()/
--  set_vacancy_open() are SECURITY DEFINER and are the only doors in.
revoke all on public.vacancies from anon;
revoke all on public.vacancies from authenticated;
grant select on public.vacancies to authenticated;


-- ---------------------------------------------------------------------------
--  2. Validating a vacancy — the core fields, then the page
-- ---------------------------------------------------------------------------
create or replace function public.check_vacancy(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_key     text := lower(btrim(coalesce(p->>'key', '')));
  v_cat     text := lower(btrim(coalesce(p->>'category', '')));
  v_title   text := btrim(coalesce(p->>'title', ''));
  v_summary text := btrim(coalesce(p->>'summary', ''));
begin
  if v_key = '' then
    return 'The role needs a short name for the website to use, like office_admin.';
  end if;
  if v_key !~ '^[a-z0-9_]{2,40}$' then
    return 'The website name must be 2 to 40 characters, lower case letters, '
        || 'numbers and underscores only. No spaces.';
  end if;
  if v_cat not in ('administration', 'education', 'community_outreach', 'event_management') then
    return 'Choose which of the four areas on the Vacancies page this role belongs to.';
  end if;
  if v_title = '' then
    return 'The role needs a title, like Office Administrator.';
  end if;
  if length(v_title) > 100 then
    return 'The title is ' || length(v_title) || ' characters. The limit is 100.';
  end if;
  if v_summary = '' then
    return 'The role needs a one or two line summary for its card on the Vacancies page.';
  end if;
  if length(v_summary) > 220 then
    return 'The summary is ' || length(v_summary) || ' characters. The limit is 220.';
  end if;
  return null;
end $$;

create or replace function public.check_vacancy_page(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_item jsonb;
  v_n    int;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return 'The role page did not arrive as expected. Reload and try again.';
  end if;

  if jsonb_typeof(p->'responsibilities') <> 'array' then
    return 'The role needs at least one responsibility listed.';
  end if;
  v_n := jsonb_array_length(p->'responsibilities');
  if v_n < 1 or v_n > 8 then
    return 'There are ' || v_n || ' responsibilities listed. There must be between 1 and 8.';
  end if;
  for v_item in select * from jsonb_array_elements(p->'responsibilities') loop
    if jsonb_typeof(v_item) <> 'string' or btrim(v_item #>> '{}') = '' then
      return 'Every responsibility needs some wording.';
    end if;
    if length(btrim(v_item #>> '{}')) > 200 then
      return 'A responsibility is too long. The limit is 200 characters.';
    end if;
  end loop;

  --  Optional — a role can be open about what it is looking for.
  if p ? 'requirements' then
    if jsonb_typeof(p->'requirements') <> 'array' then
      return 'What the role is looking for did not arrive as expected.';
    end if;
    if jsonb_array_length(p->'requirements') > 8 then
      return 'There are more than eight things the role is looking for. Eight is the most '
          || 'that reads well on the page.';
    end if;
    for v_item in select * from jsonb_array_elements(p->'requirements') loop
      if jsonb_typeof(v_item) <> 'string' or btrim(v_item #>> '{}') = '' then
        return 'Every requirement needs some wording.';
      end if;
      if length(btrim(v_item #>> '{}')) > 200 then
        return 'A requirement is too long. The limit is 200 characters.';
      end if;
    end loop;
  end if;

  --  Optional — e.g. "A few hours a week, flexible around prayer times".
  if p ? 'commitment' and length(btrim(coalesce(p->>'commitment', ''))) > 120 then
    return 'The time commitment is too long. The limit is 120 characters.';
  end if;

  --  Optional. If given, it must be a real date and not already past —
  --  nobody should be able to post a vacancy that closed yesterday.
  if p ? 'closing_date' and btrim(coalesce(p->>'closing_date', '')) <> '' then
    begin
      if (p->>'closing_date')::date < current_date then
        return 'The closing date has already passed.';
      end if;
    exception when others then
      return 'The closing date is not a valid date.';
    end;
  end if;

  if length(p::text) > 6000 then
    return 'There is too much here. Shorten the summary or use fewer rows.';
  end if;
  return null;
end $$;


-- ---------------------------------------------------------------------------
--  3. Posting and editing — ONE button, "Post Vacancy", because that is
--     what was asked for. Courses keeps "create the class" and "write its
--     page" as two separate admin actions because a class can go weeks
--     between the two; a vacancy's core details and its page are written
--     in the same sitting by the same person, so one function taking both
--     at once is the honest shape here, not a shortcut past 047's pattern.
-- ---------------------------------------------------------------------------
create or replace function public.save_vacancy(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key    text := lower(btrim(coalesce(p->>'key', '')));
  v_page   jsonb := coalesce(p->'page', '{}'::jsonb);
  v_why    text;
  v_new    boolean;
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may post or change a vacancy.'
      using errcode = '42501';
  end if;

  v_why := public.check_vacancy(p);
  if v_why is not null then raise exception '%', v_why using errcode = 'check_violation'; end if;
  v_why := public.check_vacancy_page(v_page);
  if v_why is not null then raise exception '%', v_why using errcode = 'check_violation'; end if;

  perform 1 from public.vacancies where masjid_id = v_masjid and key = v_key for update;
  v_new := not found;

  insert into public.vacancies (masjid_id, key, category, title, summary, page, sort_order, created_by)
  values (v_masjid, v_key, lower(btrim(p->>'category')), btrim(p->>'title'), btrim(p->>'summary'),
          v_page, coalesce(nullif(btrim(coalesce(p->>'sort_order', '')), '')::int, 0), auth.uid())
  on conflict (masjid_id, key) do update
    --  is_open is NOT reset here — editing a closed vacancy must not
    --  silently put it back on the live site. set_vacancy_open() is the
    --  only way that changes.
    set category = excluded.category, title = excluded.title, summary = excluded.summary,
        page = excluded.page, sort_order = excluded.sort_order;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), case when v_new then 'vacancy_posted' else 'vacancy_edited' end,
          jsonb_build_object('key', v_key, 'title', btrim(p->>'title')));

  return jsonb_build_object('key', v_key, 'is_new', v_new);
end $$;

revoke all     on function public.save_vacancy(jsonb) from public, anon;
grant  execute on function public.save_vacancy(jsonb) to authenticated;

comment on function public.save_vacancy(jsonb) is
  'The only way to post or edit a vacancy. A new one is open (live) the moment it is posted — see the header for why there is no separate "go live" step.';

create or replace function public.set_vacancy_open(p_key text, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_title text; v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open or close a vacancy.'
      using errcode = '42501';
  end if;
  update public.vacancies set is_open = p_open
   where masjid_id = v_masjid and key = lower(btrim(p_key))
  returning title into v_title;
  if not found then
    raise exception 'There is no vacancy with that name on the website.' using errcode = 'no_data_found';
  end if;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), case when p_open then 'vacancy_opened' else 'vacancy_closed' end,
          jsonb_build_object('key', lower(btrim(p_key)), 'title', v_title));
  return jsonb_build_object('key', lower(btrim(p_key)), 'is_open', p_open);
end $$;

revoke all     on function public.set_vacancy_open(text, boolean) from public, anon;
grant  execute on function public.set_vacancy_open(text, boolean) to authenticated;


-- ---------------------------------------------------------------------------
--  4. What the public site sees, and what the admin portal sees
--
--  TWO public overloads for the same reason courses_public() has two: the
--  logged-out website calls the zero-arg form (whichever masjid the row
--  itself resolves to) while a page that must name its masjid explicitly —
--  this one, going by cfg.MASJID the same way index_template.html's own
--  courses_public call already does — calls the one-argument form.
-- ---------------------------------------------------------------------------
create or replace function public.vacancies_public()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.key), '[]'::jsonb)
    from (
      select v.key, v.title, v.category, v.summary, v.page, v.sort_order
        from public.vacancies v
       where v.masjid_id = coalesce(public.current_masjid(), public.sole_masjid())
         and v.is_open
    ) x;
$$;

create or replace function public.vacancies_public(p_masjid text)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.key), '[]'::jsonb)
    from (
      select v.key, v.title, v.category, v.summary, v.page, v.sort_order
        from public.vacancies v
       where v.masjid_id = public.masjid_id_for(p_masjid)
         and v.is_open
    ) x;
$$;

revoke all     on function public.vacancies_public() from public;
revoke all     on function public.vacancies_public(text) from public;
grant  execute on function public.vacancies_public() to anon, authenticated;
grant  execute on function public.vacancies_public(text) to anon, authenticated;

create or replace function public.vacancies_admin_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may manage vacancies.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_order, x.key)
      from (
        select v.key, v.title, v.category, v.summary, v.page, v.is_open, v.sort_order, v.created_at,
               (select count(*) from public.vacancy_applications a
                 where a.vacancy_id = v.id) as applicants
          from public.vacancies v
         where v.masjid_id = public.current_masjid()
      ) x
  ), '[]'::jsonb);
end $$;

revoke all     on function public.vacancies_admin_list() from public, anon;
grant  execute on function public.vacancies_admin_list() to authenticated;


-- ---------------------------------------------------------------------------
--  5. Extending vacancy_applications for a FULL application against an
--     open posting — name/email/phone already there (176), everything
--     below is new. vacancy_id null means the 176 interest form; not null
--     means this.
-- ---------------------------------------------------------------------------
alter table public.vacancy_applications
  add column if not exists vacancy_id          uuid references public.vacancies(id),
  add column if not exists role_title          text,
  add column if not exists address_line1       text,
  add column if not exists address_line2       text,
  add column if not exists town                text,
  add column if not exists postcode            text,
  add column if not exists date_of_birth       date,
  add column if not exists cv_path             text,
  add column if not exists is_member_or_family  boolean;

comment on column public.vacancy_applications.role_title is
  'A snapshot of vacancies.title at the moment of applying, not a live join — so the office''s record of what somebody applied for does not change under them if the posting''s title is edited later, and still reads sensibly if the posting is later closed.';

comment on column public.vacancy_applications.is_member_or_family is
  'Mandatory on EVERY application, interest-only or full: the trustees instruction is that only a masjid member, or an immediate family member of one, may be considered for a position. Enforced here as well as on the form because the anon key is public — see va_membership_required below.';

do $$
begin
  --  THE MEMBERSHIP GATE. "is true" rather than "is not false" refuses a
  --  NULL as well as an explicit false — the same reasoning as
  --  va_consent_required just above this block in 176, applied to the
  --  trustees' newer instruction.
  if not exists (select 1 from pg_constraint where conname = 'va_membership_required') then
    alter table public.vacancy_applications add constraint va_membership_required
      check (is_member_or_family is true);
  end if;

  --  A FULL APPLICATION HAS A FULL APPLICATION'S FIELDS. vacancy_id null —
  --  the 176 interest form — carries none of this and is untouched by it.
  if not exists (select 1 from pg_constraint where conname = 'va_full_application_complete') then
    alter table public.vacancy_applications add constraint va_full_application_complete
      check (vacancy_id is null or (
        address_line1 is not null and town is not null and postcode is not null
        and date_of_birth is not null and cv_path is not null));
  end if;
end $$;

create index if not exists va_vacancy_idx on public.vacancy_applications (vacancy_id);


-- ---------------------------------------------------------------------------
--  6. apply_for_vacancy() — the 176 interest form — gains the same
--     membership question. Dedupe is now scoped to vacancy_id is null, so
--     registering interest never overwrites a full application somebody
--     has already made against an actual posting.
-- ---------------------------------------------------------------------------
create or replace function public.apply_for_vacancy(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_masjid   uuid := public.masjid_or_sole(payload->>'masjid');
  v_name     text := btrim(coalesce(payload->>'full_name', ''));
  v_phone    text := btrim(coalesce(payload->>'phone', ''));
  v_email    text := nullif(btrim(lower(coalesce(payload->>'email', ''))), '');
  v_category text := lower(btrim(coalesce(payload->>'category', '')));
  v_message  text := nullif(btrim(coalesce(payload->>'message', '')), '');
  v_member   boolean := (payload->>'is_member_or_family')::boolean;
  v_consent  boolean := coalesce((payload->>'consent')::boolean, false);
  v_ref      text;
  v_existing record;
begin
  if v_name = '' or length(v_name) < 2 then
    raise exception 'Please give your name.' using errcode = 'check_violation';
  end if;
  if v_phone = '' or length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then
    raise exception 'Please give a contact number the masjid can reach you on.'
      using errcode = 'check_violation';
  end if;
  if v_email is null or length(v_email) < 4 or strpos(v_email, '@') = 0 then
    raise exception 'Please give an email address the masjid can reply to.'
      using errcode = 'check_violation';
  end if;
  if v_category not in ('administration', 'education', 'community_outreach',
                         'event_management') then
    raise exception 'Please choose one of the areas on the page.'
      using errcode = 'check_violation';
  end if;
  if not coalesce(v_member, false) then
    raise exception 'The masjid can only consider members, or an immediate family member of a member, for a position.'
      using errcode = 'check_violation';
  end if;
  if not v_consent then
    raise exception 'The masjid cannot keep your details without your agreement.'
      using errcode = 'check_violation';
  end if;

  select * into v_existing
    from public.vacancy_applications
   where masjid_id = v_masjid and vacancy_id is null
     and (regexp_replace(phone, '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g')
       or lower(email) = v_email)
   order by created_at
   limit 1;

  if found then
    update public.vacancy_applications
       set full_name = v_name,
           email      = v_email,
           category   = v_category,
           message    = coalesce(v_message, message),
           is_member_or_family = v_member
     where id = v_existing.id;

    return jsonb_build_object('reference', v_existing.reference, 'already', true);
  end if;

  v_ref := 'VA-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.vacancy_application_reference_seq')::text, 4, '0');

  insert into public.vacancy_applications
    (masjid_id, reference, full_name, phone, email, category, message, is_member_or_family, consent)
  values
    (v_masjid, v_ref, v_name, v_phone, v_email, v_category, v_message, v_member, v_consent);

  return jsonb_build_object('reference', v_ref, 'already', false);
end $$;

grant execute on function public.apply_for_vacancy(jsonb) to anon, authenticated;


-- ---------------------------------------------------------------------------
--  7. apply_for_vacancy_role() — a FULL application against an open
--     posting. Same honeypot/timing-trap/rate-limit defence as every other
--     public form on this site (see the header); no CAPTCHA.
-- ---------------------------------------------------------------------------
create or replace function public.apply_for_vacancy_role(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_masjid   uuid := public.masjid_or_sole(payload->>'masjid');
  v_key      text := lower(btrim(coalesce(payload->>'vacancy', '')));
  v_vacancy  record;
  v_name     text := btrim(coalesce(payload->>'full_name', ''));
  v_phone    text := btrim(coalesce(payload->>'phone', ''));
  v_email    text := nullif(btrim(lower(coalesce(payload->>'email', ''))), '');
  v_addr1    text := btrim(coalesce(payload->>'address_line1', ''));
  v_addr2    text := nullif(btrim(coalesce(payload->>'address_line2', '')), '');
  v_town     text := btrim(coalesce(payload->>'town', ''));
  v_postcode text := btrim(coalesce(payload->>'postcode', ''));
  v_dob_raw  text := btrim(coalesce(payload->>'date_of_birth', ''));
  v_dob      date;
  v_message  text := nullif(btrim(coalesce(payload->>'message', '')), '');
  v_cv       text := btrim(coalesce(payload->>'cv_path', ''));
  v_member   boolean := (payload->>'is_member_or_family')::boolean;
  v_consent  boolean := coalesce((payload->>'consent')::boolean, false);
  v_ref      text;
  v_existing record;
begin
  select * into v_vacancy from public.vacancies
   where masjid_id = v_masjid and key = v_key and is_open;
  if not found then
    raise exception 'That role is no longer open. Please check the Vacancies page for current openings.'
      using errcode = 'no_data_found';
  end if;

  if v_name = '' or length(v_name) < 2 then
    raise exception 'Please give your name.' using errcode = 'check_violation';
  end if;
  if v_phone = '' or length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then
    raise exception 'Please give a contact number the masjid can reach you on.'
      using errcode = 'check_violation';
  end if;
  if v_email is null or length(v_email) < 4 or strpos(v_email, '@') = 0 then
    raise exception 'Please give an email address the masjid can reply to.'
      using errcode = 'check_violation';
  end if;
  if v_addr1 = '' or v_town = '' or v_postcode = '' then
    raise exception 'Please give your full address.' using errcode = 'check_violation';
  end if;
  if length(v_addr1) > 120 or length(coalesce(v_addr2, '')) > 120
     or length(v_town) > 80 or length(v_postcode) > 12 then
    raise exception 'One of the address fields is too long.' using errcode = 'check_violation';
  end if;

  begin
    v_dob := v_dob_raw::date;
  exception when others then
    v_dob := null;
  end;
  if v_dob is null or v_dob > current_date or v_dob < current_date - interval '110 years' then
    raise exception 'Please give a valid date of birth.' using errcode = 'check_violation';
  end if;

  if v_cv = '' then
    raise exception 'Please attach your CV before submitting.' using errcode = 'check_violation';
  end if;
  --  The upload has to have actually happened — a payload cannot simply
  --  name a path that was never written to the bucket. Checked here, not
  --  only client-side, for the same reason everything else in this
  --  function is.
  if not exists (select 1 from storage.objects
                  where bucket_id = 'vacancy-cvs' and name = v_cv) then
    raise exception 'Your CV did not finish uploading. Please try again.'
      using errcode = 'check_violation';
  end if;

  if not coalesce(v_member, false) then
    raise exception 'The masjid can only consider members, or an immediate family member of a member, for a position.'
      using errcode = 'check_violation';
  end if;
  if not v_consent then
    raise exception 'The masjid cannot keep your details without your agreement.'
      using errcode = 'check_violation';
  end if;

  --  Applying twice to the SAME role updates what is already there, the
  --  same reasoning as 176's interest form — but scoped to this vacancy, so
  --  applying to a second, different open role is never mistaken for the
  --  same application.
  select * into v_existing
    from public.vacancy_applications
   where masjid_id = v_masjid and vacancy_id = v_vacancy.id
     and (regexp_replace(phone, '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g')
       or lower(email) = v_email)
   order by created_at
   limit 1;

  if found then
    update public.vacancy_applications
       set full_name = v_name, email = v_email,
           address_line1 = v_addr1, address_line2 = v_addr2, town = v_town, postcode = v_postcode,
           date_of_birth = v_dob, cv_path = v_cv, message = coalesce(v_message, message),
           is_member_or_family = v_member
     where id = v_existing.id;

    return jsonb_build_object('reference', v_existing.reference, 'already', true);
  end if;

  v_ref := 'VA-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.vacancy_application_reference_seq')::text, 4, '0');

  insert into public.vacancy_applications
    (masjid_id, reference, vacancy_id, role_title, full_name, phone, email, category, message,
     address_line1, address_line2, town, postcode, date_of_birth, cv_path,
     is_member_or_family, consent)
  values
    (v_masjid, v_ref, v_vacancy.id, v_vacancy.title, v_name, v_phone, v_email, v_vacancy.category, v_message,
     v_addr1, v_addr2, v_town, v_postcode, v_dob, v_cv,
     v_member, v_consent);

  return jsonb_build_object('reference', v_ref, 'already', false);
end $$;

grant execute on function public.apply_for_vacancy_role(jsonb) to anon, authenticated;

comment on function public.apply_for_vacancy_role(jsonb) is
  'Applying to an actually-posted, open vacancy. Refuses a closed/unknown role, a missing field, an unverified CV upload, or a membership answer that is not true.';


-- ---------------------------------------------------------------------------
--  8. The CV itself — a private bucket, rate-limited the same way
--     bmcc_upload_allowed() (db/059) rate-limits certificate uploads, just
--     tighter: 5 an hour rather than 10, because a CV is a more sensitive
--     document than a charity certificate and this form has no CAPTCHA
--     behind it.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vacancy-cvs', 'vacancy-cvs', false, 5242880,
        array['application/pdf', 'application/msword',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.vacancy_cv_upload_allowed()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select (
    select count(*) from storage.objects
     where bucket_id = 'vacancy-cvs' and created_at > now() - interval '1 hour'
  ) < 5;
$$;

drop policy if exists vacancy_cv_insert on storage.objects;
drop policy if exists vacancy_cv_read   on storage.objects;
drop policy if exists vacancy_cv_delete on storage.objects;

create policy vacancy_cv_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'vacancy-cvs' and public.vacancy_cv_upload_allowed());

create policy vacancy_cv_read on storage.objects
  for select to authenticated
  using (bucket_id = 'vacancy-cvs' and public.verified_admin());

create policy vacancy_cv_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'vacancy-cvs' and public.verified_admin());


-- ---------------------------------------------------------------------------
--  9. Deleting a CV for real — db/060's own lesson, applied here instead of
--     repeated past it.
--
--     `delete from storage.objects` does not delete the file. Supabase say so
--     themselves, in so many words, in the comment on db/060 that fixed this
--     exact mistake for the BMCC certificate: it only drops the metadata row
--     and leaves the object itself in the bucket, orphaned. Worse here —
--     storage.protect_delete() (a trigger that did not exist when 060 was
--     written) now REFUSES a direct delete outright rather than quietly
--     doing the wrong thing. Either way, a plain `delete` is not the fix.
--
--     So this is 060's queue again, not reinvented — a path is written down
--     before the only row naming it is destroyed, an hourly sweep sends it to
--     the real Storage API, and the response is read back before the queue
--     entry is cleared. It shares 060's app_settings keys (storage_url is
--     already set; storage_key is the same service_role key db/060 asked for
--     by hand and is reused here rather than asked for twice). Until that key
--     is pasted in, this sweep does exactly what sweep_bmcc_certificates()
--     already does without it: writes vacancy_cv_sweep_not_configured to
--     admin_audit and deletes nothing. That is the existing, known state of
--     this project today — not a new gap this migration opens.
-- ---------------------------------------------------------------------------
create table if not exists public.vacancy_cv_purge_queue (
  path        text primary key,
  masjid_id   uuid        not null references public.masjids(id) on delete cascade,
  queued_at   timestamptz not null default now(),
  request_id  bigint,
  sent_at     timestamptz,
  attempts    integer     not null default 0,
  last_error  text
);

comment on table public.vacancy_cv_purge_queue is
  'CVs whose application row has been deleted (or which were never claimed by one) and whose file still has to be removed through the Storage API. A row here means a file is still in the bucket that should not be. An empty table is the healthy state.';

alter table public.vacancy_cv_purge_queue enable row level security;
-- No policies, deliberately — same reasoning as bmcc_certificate_purge_queue:
-- reachable only by the SECURITY DEFINER functions below.

create index if not exists vacancy_cv_purge_queue_pending
  on public.vacancy_cv_purge_queue (queued_at)
  where request_id is null;


-- ---------------------------------------------------------------------------
--  10. purge_old_vacancy_applications() — unchanged in what it deletes and
--      when, except that a CV's path is now QUEUED before its row is
--      destroyed, not deleted-from-storage directly.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_vacancy_applications(dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_m uuid; v_n int; v_total int := 0; v_queued int;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge vacancy applications.'
      using errcode = '42501';
  end if;

  for v_m in select * from public.masjids_to_purge() loop
    if dry_run then
      select count(*) into v_n from public.vacancy_applications
       where masjid_id = v_m and created_at < now() - interval '12 months';
      v_total := v_total + v_n;
      continue;
    end if;

    with expiring as materialized (
      select id, cv_path from public.vacancy_applications
       where masjid_id = v_m and created_at < now() - interval '12 months'
    ),
    -- FIRST. The path is written down while the row that holds it still
    -- exists — reversing these two statements is 060's whole bug again.
    queued as (
      insert into public.vacancy_cv_purge_queue (path, masjid_id)
      select cv_path, v_m from expiring where cv_path is not null
      on conflict (path) do nothing
      returning 1
    ),
    gone as (
      delete from public.vacancy_applications a
       using expiring e
       where a.id = e.id
      returning 1
    )
    select (select count(*) from queued), (select count(*) from gone)
      into v_queued, v_n;

    if v_n > 0 then
      insert into public.admin_audit (masjid_id, action, detail)
      values (v_m, 'vacancy_applications_purged', jsonb_build_object('deleted', v_n));
    end if;

    v_total := v_total + v_n;
  end loop;

  if dry_run then
    return jsonb_build_object('would_delete', v_total, 'dry_run', true);
  end if;
  return jsonb_build_object('deleted', v_total, 'dry_run', false);
end $$;


-- ---------------------------------------------------------------------------
--  11. Orphaned CVs — uploaded, then never actually submitted (the person
--      closed the tab, the network dropped between the upload and the RPC
--      call). Nothing references them, so nothing else would ever queue
--      them. The grace period is not optional, the same reasoning as 060's:
--      between the upload finishing and apply_for_vacancy_role being called
--      a file is, briefly, exactly what an orphan looks like, and 48 hours
--      is far longer than that gap.
-- ---------------------------------------------------------------------------
create or replace function public.queue_orphaned_vacancy_cvs(grace_hours integer default 48)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_queued int;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may sweep vacancy CVs.'
      using errcode = '42501';
  end if;

  with orphans as (
    select o.name as path
      from storage.objects o
     where o.bucket_id = 'vacancy-cvs'
       and o.created_at < now() - make_interval(hours => greatest(grace_hours, 1))
       and not exists (select 1 from public.vacancy_applications a
                        where a.cv_path = o.name)
  ),
  queued as (
    insert into public.vacancy_cv_purge_queue (path, masjid_id)
    select o.path, (select id from public.masjids order by created_at limit 1)
      from orphans o
    on conflict (path) do nothing
    returning 1
  )
  select count(*) into v_queued from queued;

  if v_queued > 0 then
    insert into public.admin_audit (masjid_id, action, detail)
    select m.id, 'vacancy_cv_orphans_queued', jsonb_build_object('queued', v_queued)
      from public.masjids m order by m.created_at limit 1;
  end if;

  return v_queued;
end $$;

revoke all on function public.queue_orphaned_vacancy_cvs(integer) from public, anon, authenticated;


-- ---------------------------------------------------------------------------
--  12. sweep_vacancy_cvs() — send, then read back what came of earlier
--      sends. Reaping first and sending second is deliberate, the same as
--      060's sweep: a request sent in this run cannot possibly have a
--      response yet.
-- ---------------------------------------------------------------------------
create or replace function public.sweep_vacancy_cvs()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp, extensions
as $$
declare
  v_url    text;
  v_key    text;
  v_done   int := 0;
  v_masjid uuid;
  r        record;
  v_id     bigint;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may sweep vacancy CVs.'
      using errcode = '42501';
  end if;

  select id into v_masjid from public.masjids order by created_at limit 1;

  select value into v_url from public.app_settings
   where masjid_id = v_masjid and key = 'storage_url';
  select value into v_key from public.app_settings
   where masjid_id = v_masjid and key = 'storage_key';

  --  Nothing is deleted from the queue when we cannot reach storage — the
  --  same degraded-but-safe state db/060 leaves sweep_bmcc_certificates() in
  --  until the service_role key is pasted in by hand. Both sweeps share the
  --  one key; this is not a second secret to configure.
  if v_url is null or v_key is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'vacancy_cv_sweep_not_configured',
            jsonb_build_object('missing', case when v_url is null then 'storage_url'
                                               else 'storage_key' end,
                               'waiting',
                               (select count(*) from public.vacancy_cv_purge_queue)));
    return 0;
  end if;

  -- REAP. 200 and 204 are success. So is 404: the file is not there, which is
  -- the state we were trying to reach, and leaving the row would retry for ever.
  for r in
    select q.path, q.request_id, resp.status_code, resp.error_msg
      from public.vacancy_cv_purge_queue q
      join net._http_response resp on resp.id = q.request_id
     where q.request_id is not null
  loop
    if r.status_code in (200, 204, 404) then
      delete from public.vacancy_cv_purge_queue where path = r.path;
      v_done := v_done + 1;
    else
      update public.vacancy_cv_purge_queue
         set request_id = null,
             last_error = coalesce(r.error_msg, 'HTTP ' || coalesce(r.status_code::text, '?'))
       where path = r.path;
    end if;
  end loop;

  -- SEND. Anything never sent, or sent and found to have failed above.
  for r in
    select path from public.vacancy_cv_purge_queue
     where request_id is null and attempts < 10
     order by queued_at
     limit 100
  loop
    select net.http_delete(
             url     := rtrim(v_url, '/') || '/object/vacancy-cvs/' || r.path,
             headers := jsonb_build_object(
                          'Authorization', 'Bearer ' || v_key))
      into v_id;

    update public.vacancy_cv_purge_queue
       set request_id = v_id, sent_at = now(), attempts = attempts + 1
     where path = r.path;
  end loop;

  if v_done > 0 then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'vacancy_cvs_deleted',
            jsonb_build_object('deleted', v_done,
                               'still_queued',
                               (select count(*) from public.vacancy_cv_purge_queue)));
  end if;

  return v_done;
end $$;

revoke all on function public.sweep_vacancy_cvs() from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  13. The schedule, outside the transaction. Offset from db/060's bmcc
--      times (3:55/4:05/:20) so the two sweeps never contend.
-- ---------------------------------------------------------------------------
select cron.unschedule('queue-orphaned-vacancy-cvs')
 where exists (select 1 from cron.job where jobname = 'queue-orphaned-vacancy-cvs');
select cron.schedule('queue-orphaned-vacancy-cvs', '10 4 * * *',
                     $$select public.queue_orphaned_vacancy_cvs(48)$$);

select cron.unschedule('sweep-vacancy-cvs')
 where exists (select 1 from cron.job where jobname = 'sweep-vacancy-cvs');
select cron.schedule('sweep-vacancy-cvs', '35 * * * *',
                     $$select public.sweep_vacancy_cvs()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then prove the guarantees that matter are real. ALL of these must fail:
--
--    -- no membership answer at all
--    select public.apply_for_vacancy(
--      '{"full_name":"A Test","phone":"07700900000","email":"a@example.com",
--        "category":"administration","consent":true}'::jsonb);
--
--    -- membership answered "no"
--    select public.apply_for_vacancy(
--      '{"full_name":"A Test","phone":"07700900000","email":"a@example.com",
--        "category":"administration","consent":true,
--        "is_member_or_family":false}'::jsonb);
--
--    -- applying to a role that was never posted
--    select public.apply_for_vacancy_role(
--      '{"vacancy":"not_a_real_role","full_name":"A Test"}'::jsonb);
--
--    -- a CV path that was never uploaded
--    select public.save_vacancy('{"key":"probe_role","category":"administration",
--      "title":"Probe","summary":"Probe role.",
--      "page":{"responsibilities":["Do the probe thing."]}}'::jsonb);
--    select public.apply_for_vacancy_role(
--      '{"vacancy":"probe_role","full_name":"A Test","phone":"07700900000",
--        "email":"a@example.com","address_line1":"1 Test St","town":"Bolton",
--        "postcode":"BL1 1AA","date_of_birth":"1990-01-01",
--        "cv_path":"nonexistent.pdf","is_member_or_family":true,
--        "consent":true}'::jsonb);
--    delete from public.vacancies where key = 'probe_role';
--
--  And this must return nothing at all when signed out:
--
--    select count(*) from public.vacancies;
-- ===========================================================================
