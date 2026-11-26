-- ===========================================================================
--  176_vacancy_applications.sql — people applying for a role on the Vacancies
--  page
--
--  Asked for 26 November 2026, straight after the Vacancies page itself: a
--  page that invites somebody to apply is not finished until there is
--  somewhere for what they typed to go. Same mistake this repo has made
--  before — see db/023's header — so this follows that file's shape on
--  purpose rather than inventing a second one.
--
--  WHAT THIS TABLE HOLDS AND WHY EACH FIELD IS HERE. Under Article 5(1)(c)
--  every field needs a reason, and "it was on the form" is not one:
--
--    full_name, phone, email   how the masjid gets back to them. Both
--                              required — a CV is no use to the office if
--                              the only contact that bounced is the one
--                              they relied on.
--    category                  which of the four areas on the Vacancies
--                              page they are applying towards. Fixed to the
--                              four the page actually shows (see the CHECK
--                              below) — a free-text field here would let the
--                              office receive an application for a role the
--                              public page never offered.
--    message                   whatever they wrote about themselves.
--                              Optional: the categories are broad plans, not
--                              job specs with questions to answer.
--    consent, consented_at     the lawful basis. Consent, because applying
--                              is voluntary and they must be able to say no.
--
--  ADMIN ONLY, NOT hall_office. db/023's volunteers are a rota the hall
--  office runs day to day; this is recruitment, which is the committee's own
--  decision, and the only office-facing roles in this codebase admitted to
--  hall_office are the ones that were already theirs before this table
--  existed. Widening that later is a decision to write down here, not a
--  default to fall into.
--
--  No role is live yet (see index_template.html's svc-vacancies page) — this
--  exists so the form has somewhere to write the moment one is.
--
--  Prerequisites: 011 (verified_admin), and admin_audit.
--  Idempotent — safe to run twice.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.verified_admin()') is null then
    raise exception 'public.verified_admin() does not exist. Run 011_require_two_step.sql first.';
  end if;
  if to_regclass('public.admin_audit') is null then
    raise exception 'public.admin_audit does not exist. Run the earlier migrations first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  1. The table
-- ---------------------------------------------------------------------------
create table if not exists public.vacancy_applications (
  id                uuid primary key default gen_random_uuid(),
  reference         text        not null unique,

  full_name         text        not null,
  phone             text        not null,
  email             text        not null,

  category          text        not null,
  message           text,

  consent           boolean     not null,
  consented_at      timestamptz not null default now(),

  -- The office's own working state. Nothing the applicant sees.
  status            text        not null default 'waiting',
  contacted_at      timestamptz,
  contacted_by      uuid,
  note              text,

  created_at        timestamptz not null default now()
);

-- Constraints as a separate idempotent block so re-running the file does not
-- fail on an already-constrained table.
do $$
begin
  --  THE FOUR CATEGORIES, AND ONLY THOSE FOUR. Matched byte for byte against
  --  the tiles on the Vacancies page — Administration, Education, Community
  --  Outreach, Event Management — so this table can never hold an
  --  application for a category the public page never offered.
  if not exists (select 1 from pg_constraint where conname = 'va_category_known') then
    alter table public.vacancy_applications add constraint va_category_known
      check (category in ('administration', 'education', 'community_outreach',
                           'event_management'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'va_status_known') then
    alter table public.vacancy_applications add constraint va_status_known
      check (status in ('waiting', 'contacted', 'shortlisted', 'declined'));
  end if;

  --  ---------------------------------------------------------------------
  --   CONSENT IS THE LAWFUL BASIS, SO A ROW WITHOUT IT IS NOT LAWFUL TO HOLD
  --
  --   Not "the form has a tick box". The row cannot exist without the tick,
  --   which means no amount of careless code upstream can create one.
  --  ---------------------------------------------------------------------
  if not exists (select 1 from pg_constraint where conname = 'va_consent_required') then
    alter table public.vacancy_applications add constraint va_consent_required
      check (consent is true);
  end if;
end $$;

create index if not exists va_created_idx  on public.vacancy_applications (created_at desc);
create index if not exists va_status_idx   on public.vacancy_applications (status);
create index if not exists va_category_idx on public.vacancy_applications (category);

comment on table public.vacancy_applications is
  'People who have applied through the Vacancies page, before any role is actually advertised. Deleted twelve months after applying — see purge_old_vacancy_applications().';


-- ---------------------------------------------------------------------------
--  2. Row level security
--
--  Nobody reads this table without being signed in, verified at aal2, and
--  holding admin. It is a list of names, phone numbers and email addresses of
--  people applying to work or volunteer for the masjid; there is no version
--  of "public" that is right, and it is not the hall office's to read either
--  (see the header above).
--
--  There is no INSERT policy at all. The public writes through the function
--  in section 3 and nowhere else, so the shape of what can be written is
--  fixed in one place rather than being whatever the browser felt like
--  sending.
-- ---------------------------------------------------------------------------
alter table public.vacancy_applications enable row level security;

drop policy if exists va_read   on public.vacancy_applications;
drop policy if exists va_update on public.vacancy_applications;

create policy va_read on public.vacancy_applications
  for select using (public.verified_admin());

create policy va_update on public.vacancy_applications
  for update using (public.verified_admin())
          with check (public.verified_admin());

--  Supabase grants ALL on a new table in public to both anon and
--  authenticated by default, so "grant select, update" ADDS to that rather
--  than describing it. db/023 found this by reading the grants back off
--  production, not by reasoning about it — which is the only way anybody
--  finds it.
--
--  RLS was already blocking INSERT and DELETE, because there is no policy for
--  either. But a table protected only by the ABSENCE of a policy is one
--  careless "for all" policy away from being writable by any signed-in user,
--  and this one holds people's contact details.
revoke all on public.vacancy_applications from anon;
revoke all on public.vacancy_applications from authenticated;
grant select, update on public.vacancy_applications to authenticated;


-- ---------------------------------------------------------------------------
--  3. Applying
--
--  security definer, because the anon role cannot touch the table. Everything
--  the public can put in this table goes through here.
-- ---------------------------------------------------------------------------
create or replace function public.apply_for_vacancy(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name     text := btrim(coalesce(payload->>'full_name', ''));
  v_phone    text := btrim(coalesce(payload->>'phone', ''));
  v_email    text := nullif(btrim(lower(coalesce(payload->>'email', ''))), '');
  v_category text := lower(btrim(coalesce(payload->>'category', '')));
  v_message  text := nullif(btrim(coalesce(payload->>'message', '')), '');
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
  if not v_consent then
    raise exception 'The masjid cannot keep your details without your agreement.'
      using errcode = 'check_violation';
  end if;

  --  Applying twice is not an error worth showing anybody. Somebody who
  --  presses the button again a fortnight later, having changed their mind
  --  about which area, gets their own reference back and one row updated,
  --  rather than an error message or a duplicate in the office's list.
  --  Matched on phone first because that is the field everybody fills in.
  select * into v_existing
    from public.vacancy_applications
   where regexp_replace(phone, '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g')
      or lower(email) = v_email
   order by created_at
   limit 1;

  if found then
    update public.vacancy_applications
       set full_name = v_name,
           email      = v_email,
           category   = v_category,
           message     = coalesce(v_message, message)
     where id = v_existing.id;

    return jsonb_build_object('reference', v_existing.reference, 'already', true);
  end if;

  --  VA-26-0001. The year is the masjid's own reference, not a key.
  v_ref := 'VA-' || to_char(now(), 'YY') || '-' ||
           lpad((select count(*) + 1 from public.vacancy_applications)::text, 4, '0');

  insert into public.vacancy_applications
    (reference, full_name, phone, email, category, message, consent)
  values
    (v_ref, v_name, v_phone, v_email, v_category, v_message, v_consent);

  return jsonb_build_object('reference', v_ref, 'already', false);
end $$;

grant execute on function public.apply_for_vacancy(jsonb) to anon, authenticated;

comment on function public.apply_for_vacancy(jsonb) is
  'The only way the public can write to vacancy_applications. Refuses rows without consent or an unknown category.';


-- ---------------------------------------------------------------------------
--  4. What the office sees
-- ---------------------------------------------------------------------------
create or replace function public.vacancy_application_summary()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when not public.verified_admin()
              then jsonb_build_object('allowed', false)
         else jsonb_build_object(
           'allowed',             true,
           'total',               count(*),
           'waiting',             count(*) filter (where status = 'waiting'),
           'contacted',           count(*) filter (where status = 'contacted'),
           'shortlisted',         count(*) filter (where status = 'shortlisted'),
           'declined',            count(*) filter (where status = 'declined'),
           'administration',      count(*) filter (where category = 'administration' and status <> 'declined'),
           'education',           count(*) filter (where category = 'education' and status <> 'declined'),
           'community_outreach',  count(*) filter (where category = 'community_outreach' and status <> 'declined'),
           'event_management',    count(*) filter (where category = 'event_management' and status <> 'declined'))
         end
    from public.vacancy_applications
$$;

revoke all     on function public.vacancy_application_summary() from public, anon;
grant  execute on function public.vacancy_application_summary() to authenticated;

create or replace function public.set_vacancy_application_status(
  p_reference text, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_status not in ('waiting', 'contacted', 'shortlisted', 'declined') then
    raise exception 'Unknown status %', p_status using errcode = 'check_violation';
  end if;

  update public.vacancy_applications
     set status       = p_status,
         note         = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note),
         contacted_at = case when p_status = 'waiting' then contacted_at else now() end,
         contacted_by = case when p_status = 'waiting' then contacted_by else auth.uid() end
   where reference = p_reference;

  if not found then
    raise exception 'No application with reference %', p_reference using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (action, detail)
  values ('vacancy_application_status', jsonb_build_object(
            'reference', p_reference, 'status', p_status, 'by', auth.uid()));
end $$;

revoke all     on function public.set_vacancy_application_status(text, text, text) from public, anon;
grant  execute on function public.set_vacancy_application_status(text, text, text) to authenticated;


-- ---------------------------------------------------------------------------
--  5. Twelve months, on a timer
--
--  The website tells applicants their details are kept for twelve months. Any
--  published retention period is a promise about what happens automatically,
--  not a reminder for somebody to act on — see db/023 and the migration it
--  cites for what happens when a promise like that depends on somebody
--  remembering.
--
--  No admin check here, deliberately, for the reason db/023 sets out at
--  length: pg_cron holds no JWT, auth.uid() is null, and a purge that checks
--  for an administrator would raise every night and delete nothing. Access is
--  controlled by the revoke below, which is the right tool for a job that
--  nobody signs in to do.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_vacancy_applications(dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n int;
begin
  if dry_run then
    select count(*) into v_n
      from public.vacancy_applications
     where created_at < now() - interval '12 months';
    return jsonb_build_object('would_delete', v_n, 'dry_run', true);
  end if;

  delete from public.vacancy_applications
   where created_at < now() - interval '12 months';
  get diagnostics v_n = row_count;

  if v_n > 0 then
    insert into public.admin_audit (action, detail)
    values ('vacancy_applications_purged', jsonb_build_object('deleted', v_n));
  end if;

  return jsonb_build_object('deleted', v_n, 'dry_run', false);
end $$;

revoke all on function public.purge_old_vacancy_applications(boolean) from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  6. The schedule, outside the transaction
--
--  03:27, two minutes after the volunteers purge, so a slow night does not
--  have several of them contending at once.
-- ---------------------------------------------------------------------------
select cron.unschedule('purge-vacancy-applications')
 where exists (select 1 from cron.job where jobname = 'purge-vacancy-applications');

select cron.schedule('purge-vacancy-applications', '27 3 * * *',
                     $$select public.purge_old_vacancy_applications()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then prove the two guarantees are real. BOTH of these must fail:
--
--    select public.apply_for_vacancy(
--      '{"full_name":"A Test","phone":"07700900000","email":"a@example.com",
--        "category":"administration"}'::jsonb);                  -- no consent
--
--    insert into public.vacancy_applications
--      (reference, full_name, phone, email, category, consent)
--    values ('VA-TEST-X','No Consent','07700900001','a@example.com',
--            'administration', false);
--
--  And this must return nothing at all when signed out:
--
--    select count(*) from public.vacancy_applications;
-- ===========================================================================
