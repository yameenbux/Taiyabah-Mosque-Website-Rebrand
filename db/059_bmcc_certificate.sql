-- ===========================================================================
--  059_bmcc_certificate.sql — the BMCC certificate a charity must show
--
--  Bolton Masjid Chanda Committee issues a certificate to a charity that is
--  cleared to collect in Bolton's masjids. The masjid asks to see it before
--  approving a collection, and it must be no more than three months old.
--
--  Until now that happened on paper, after the form. It is now part of the
--  form, and a request cannot be made without one.
--
--  WHY THE BUCKET IS PRIVATE, UNLIKE `notices`
--  -------------------------------------------
--  042 created a PUBLIC bucket and said plainly that anything in it is on the
--  internet to anybody with the address. That was right for posters. It is
--  wrong for this: a BMCC certificate carries an organisation's name, its
--  registration, a committee signature and a date, and the charity handed it
--  over to satisfy one masjid, not to publish it. So `bmcc` is private, and
--  nothing but a verified administrator can read it back.
--
--  WHY ANON MAY WRITE TO IT
--  ------------------------
--  The applicant is a stranger filling in a public form. There is no account
--  to sign in to and there should not be one — requiring a login to apply
--  would turn a five-minute form into a support problem. So `anon` may INSERT
--  into this one bucket and may do nothing else: no select, no list, no
--  update, no delete. It cannot read back even the file it just wrote.
--
--  THE HONEST RISK, STATED. Anybody who finds the anon key — it is in the
--  page source of every page, by design — can push 5 MB files into this
--  bucket until somebody notices. What they CANNOT do is read anything out of
--  it, list it, overwrite somebody else's certificate, or serve files from it
--  to anybody else, so it is useless as free file hosting and useless as a
--  way to reach the masjid's data. The exposure is storage cost and noise.
--  An orphan sweep belongs in a later migration; the office should be told
--  that a sudden jump in bucket size is worth a look.
--
--  WHY THE THREE-MONTH RULE IS IN THE FUNCTION AND NOT A CHECK CONSTRAINT
--  ---------------------------------------------------------------------
--  It wants to compare the certificate's date against the day the form was
--  submitted, and `submitted_at::date` is STABLE, not IMMUTABLE — it depends
--  on the TimeZone setting — so Postgres will not accept it in a CHECK. The
--  constraint below therefore only holds the parts that are immutable, and
--  the dated rule lives in request_charity_collection(), which is the ONLY
--  way anything reaches this table: `anon` and `authenticated` hold no INSERT
--  on it (030), and the single insert policy is for the definer.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  The columns.
--
--  Nullable at the table, required by the function. The two rows that already
--  exist were submitted before this rule and have no certificate; giving them
--  a made-up path to satisfy a NOT NULL would be writing something false into
--  the masjid's own record. The office screen shows them as predating the
--  rule instead.
-- ---------------------------------------------------------------------------
alter table public.charity_collections
  add column if not exists bmcc_certificate_path text,
  add column if not exists bmcc_certificate_date date,
  add column if not exists students_total        integer,
  add column if not exists students_boarding     integer;

comment on column public.charity_collections.bmcc_certificate_path is
  'Object path inside the private `bmcc` storage bucket. Null only for requests submitted before September 2026, when the certificate was shown on paper.';
comment on column public.charity_collections.bmcc_certificate_date is
  'The date printed on the BMCC certificate, as typed by the applicant. Checked against three months in request_charity_collection().';
comment on column public.charity_collections.students_total is
  'Optional. How many students the charity''s madrasah or school has.';
comment on column public.charity_collections.students_boarding is
  'Optional. How many of students_total board there.';

--  Both or neither: a date with no file, or a file with no date, is a record
--  nobody can act on.
alter table public.charity_collections
  drop constraint if exists cc_certificate_paired;
alter table public.charity_collections
  add constraint cc_certificate_paired check (
    (bmcc_certificate_path is null) = (bmcc_certificate_date is null)
  ) not valid;

alter table public.charity_collections
  drop constraint if exists cc_certificate_path_sane;
alter table public.charity_collections
  add constraint cc_certificate_path_sane check (
    bmcc_certificate_path is null
    or (length(btrim(bmcc_certificate_path)) between 3 and 300
        and bmcc_certificate_path !~ '\.\.')
  ) not valid;

--  A boarding count larger than the total is a typo, and the office would
--  have to ring to find out which number was wrong.
alter table public.charity_collections
  drop constraint if exists cc_students_sane;
alter table public.charity_collections
  add constraint cc_students_sane check (
    (students_total    is null or students_total    between 0 and 100000)
    and (students_boarding is null or students_boarding between 0 and 100000)
    and (students_boarding is null or students_total is null
         or students_boarding <= students_total)
  ) not valid;

commit;

-- ===========================================================================
--  The bucket, and who may touch it.
-- ===========================================================================
begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bmcc', 'bmcc', false, 5242880,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update
  set public             = false,
      file_size_limit    = 5242880,
      allowed_mime_types = excluded.allowed_mime_types;

--  `bucket_id = 'bmcc'` is load-bearing in every one of these, for the reason
--  042 gives: without it they apply to every bucket this project ever gains.

--  WRITE. anon and authenticated alike, because an applicant may or may not
--  happen to be signed in to the madrasah portal, and it makes no difference
--  to whether they may hand in a certificate.
drop policy if exists bmcc_certificate_insert on storage.objects;
create policy bmcc_certificate_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'bmcc');

--  READ. Verified administrators only — the same gate as every other read of
--  an applicant's details. There is deliberately no anon select: the person
--  who uploaded a certificate cannot read it back either, which is why this
--  bucket is no use to anybody as file hosting.
drop policy if exists bmcc_certificate_read on storage.objects;
create policy bmcc_certificate_read on storage.objects
  for select to authenticated
  using (bucket_id = 'bmcc' and public.verified_admin());

--  DELETE. Only an administrator, so an applicant cannot remove the
--  certificate they submitted after the fact, and the office can clear one
--  out when the request is purged.
drop policy if exists bmcc_certificate_delete on storage.objects;
create policy bmcc_certificate_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'bmcc' and public.verified_admin());

--  No UPDATE policy at all, for anybody. Storage treats an upload to an
--  existing key as an update, so leaving it out is what stops one applicant
--  overwriting another's certificate by guessing a name.

commit;

-- ===========================================================================
--  request_charity_collection — now refuses a request with no certificate.
--
--  Everything above the certificate block is unchanged from 032/058; it is
--  repeated rather than patched because Postgres has no way to amend part of
--  a function body, and a half-quoted diff in a file nobody can run is worse
--  than a longer file that can be.
-- ===========================================================================
begin;

create or replace function public.request_charity_collection(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  NOTICE_DAYS  constant int := 14;
  HORIZON_DAYS constant int := 365;
  --  The BMCC issues these for a season, and the masjid's rule is three
  --  months. Changing it here changes the only copy that is enforced; the two
  --  forms carry their own copy so they can warn before somebody uploads, and
  --  both say the same number.
  CERT_MONTHS  constant int := 3;

  v_masjid    uuid;
  v_date      date    := (payload ->> 'requested_date')::date;
  v_email     text    := lower(btrim(payload ->> 'org_email'));
  v_paid      boolean := (payload ->> 'collector_paid')::boolean;
  v_rules_v   text    := nullif(btrim(payload ->> 'rules_version'), '');
  v_cert_path text    := nullif(btrim(payload ->> 'bmcc_certificate_path'), '');
  v_cert_date date;
  v_students  integer;
  v_boarding  integer;
  v_ref       text;
begin
  v_masjid := public.masjid_or_sole(payload ->> 'masjid');

  if v_date is null then
    raise exception 'Please choose a date for the collection';
  end if;
  if v_date < current_date then
    raise exception 'That date has already passed';
  end if;
  if v_date < current_date + NOTICE_DAYS then
    raise exception 'The masjid needs at least % days notice - the earliest date we can take is %',
      NOTICE_DAYS, to_char(current_date + NOTICE_DAYS, 'DD Mon YYYY');
  end if;
  if v_date > current_date + HORIZON_DAYS then
    raise exception 'Collections can only be requested up to a year ahead';
  end if;
  if v_paid is null then
    raise exception 'Please answer whether the collector receives a wage or commission';
  end if;
  if v_rules_v is null then
    raise exception 'The collection rules were not recorded - please reload the page and try again';
  end if;
  if not coalesce((payload ->> 'rules_accepted')::boolean, false) then
    raise exception 'The collection rules have to be accepted';
  end if;
  if not coalesce((payload ->> 'privacy_accepted')::boolean, false) then
    raise exception 'Please accept how the masjid handles this information';
  end if;

  -- ---- the BMCC certificate ------------------------------------------------
  --  Checked HERE and not only in the browser, because a form can be driven
  --  from outside one and the certificate is the whole point of the rule.
  if v_cert_path is null then
    raise exception 'Please attach your BMCC certificate - the masjid cannot take a request without one';
  end if;

  --  Cast separately so a typed-in date that is not a date says so, rather
  --  than surfacing as "invalid input syntax for type date".
  begin
    v_cert_date := (payload ->> 'bmcc_certificate_date')::date;
  exception when others then
    raise exception 'That does not look like a date. Please give the date printed on your BMCC certificate';
  end;

  if v_cert_date is null then
    raise exception 'Please give the date on your BMCC certificate';
  end if;
  if v_cert_date > current_date then
    raise exception 'The date on the certificate is in the future - please check it';
  end if;
  if v_cert_date < current_date - (CERT_MONTHS || ' months')::interval then
    raise exception 'That certificate is more than % months old. The masjid needs one issued on or after %. Please ask the BMCC for a current one.',
      CERT_MONTHS, to_char((current_date - (CERT_MONTHS || ' months')::interval)::date, 'DD Mon YYYY');
  end if;

  -- ---- the optional student numbers ---------------------------------------
  --  Optional means optional: absent, empty and null are all fine, and none
  --  of them stops a request. Only a number that cannot be true is refused.
  begin
    v_students := nullif(btrim(payload ->> 'students_total'), '')::integer;
    v_boarding := nullif(btrim(payload ->> 'students_boarding'), '')::integer;
  exception when others then
    raise exception 'Please give the student numbers as plain numbers, or leave them empty';
  end;
  if v_students is not null and v_students < 0 then
    raise exception 'The number of students cannot be negative';
  end if;
  if v_boarding is not null and v_boarding < 0 then
    raise exception 'The number of boarding students cannot be negative';
  end if;
  if v_students is not null and v_boarding is not null and v_boarding > v_students then
    raise exception 'There cannot be more boarding students than students - please check those two numbers';
  end if;

  if exists (select 1 from public.charity_collections
              where masjid_id = v_masjid
                and lower(org_email) = v_email
                and requested_date = v_date
                and status in ('new','contacted','approved')) then
    raise exception 'The masjid already has a request from this email address for that date. The office will be in touch.';
  end if;

  v_ref := 'CC-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.charity_reference_seq')::text, 4, '0');

  insert into public.charity_collections (
    masjid_id, reference, requested_date,
    org_name, org_address, org_phone, org_email, charity_number,
    collector_name, collector_role, collector_paid,
    trustee_name, trustee_phone, trustee_email,
    rules_version, rules_accepted, signed_name, privacy_accepted,
    bmcc_certificate_path, bmcc_certificate_date,
    students_total, students_boarding
  ) values (
    v_masjid, v_ref, v_date,
    btrim(payload ->> 'org_name'), btrim(payload ->> 'org_address'),
    btrim(payload ->> 'org_phone'), v_email,
    nullif(btrim(payload ->> 'charity_number'), ''),
    btrim(payload ->> 'collector_name'), btrim(payload ->> 'collector_role'), v_paid,
    btrim(payload ->> 'trustee_name'), btrim(payload ->> 'trustee_phone'),
    lower(btrim(payload ->> 'trustee_email')),
    v_rules_v, true, btrim(payload ->> 'signed_name'), true,
    v_cert_path, v_cert_date,
    v_students, v_boarding
  );

  --  The audit row stays thin, as 030 set it: a reference and a date. It does
  --  NOT gain the certificate path — admin_audit is read on a dashboard by
  --  anybody with an office login, and the path is the key to a private file.
  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'charity_collection_request',
          jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'requested_date', v_date);
end $$;

revoke all on function public.request_charity_collection(jsonb) from public;
grant execute on function public.request_charity_collection(jsonb) to anon, authenticated;

commit;
