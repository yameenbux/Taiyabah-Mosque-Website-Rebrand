-- ===========================================================================
--  _test_fees.sql          LOCAL HARNESS ONLY — NEVER RUN AGAINST SUPABASE
--
--  It creates masjids, families, children, charges and payments, and deletes
--  them again. Against production it would write test rows into the charity's
--  financial records.
--
--  Profile: fees  (stub + 068, 069, 070, 071)
--      cd db/harness && ./build.sh feestest fees
--
--  The migrations carry their own CHECKs, and those test the SHAPE — that
--  net_p is generated, that a refund cannot be positive, that every function
--  asks verified_admin(). This file tests the BEHAVIOUR: that three children
--  in one family produce the right bill, that pressing "raise charges" twice
--  charges once, and that a teacher gets nothing.
--
--  ---------------------------------------------------------------------------
--  WHY THIS RUNS AS A ROLE THAT BYPASSES RLS, AND WHY THAT IS NOT A CHEAT
--  ---------------------------------------------------------------------------
--
--  The admissions suite learned that a superuser ignores RLS, so testing as
--  one proves nothing, and it reassigns ownership to a NOSUPERUSER NOBYPASSRLS
--  role before asserting anything.
--
--  That would be the WRONG move here, and the reason is worth writing down.
--  These tables use FORCE ROW LEVEL SECURITY with no policies at all. Under
--  FORCE, the owner is subject to RLS too — so with no policies, an owner
--  without BYPASSRLS cannot read its own table, and every SECURITY DEFINER
--  function in 068-071 would fail. In Supabase the `postgres` role that owns
--  these objects HAS rolbypassrls, which is exactly why the pattern works
--  there. Reassigning to a NOBYPASSRLS role here would not be a stricter
--  test; it would be a different system.
--
--  What actually protects these tables is the privilege gate in front of RLS:
--  `revoke all ... from anon, authenticated` means a wrong policy cannot leak
--  a row, because the privilege check happens first. Test 12 asserts that,
--  and it is the one that matters.
-- ===========================================================================

\set ON_ERROR_STOP off
\timing off

create temporary table if not exists _t (n text, ok boolean, got text);

create or replace function pg_temp.t(p_name text, p_ok boolean, p_got text default null)
returns void language sql as $$
  insert into _t(n, ok, got) values ($1, $2, $3)
$$;

-- ---------------------------------------------------------------------------
--  Fixture: one masjid, three families, five children.
--
--    Khan       3 children, all here        -> the sibling discount case
--    Patel      1 child                     -> the plain case
--    Begum      1 child, no guardian email  -> the "nobody to write to" case
--    (orphan)   1 child with no family      -> the skipped case
-- ---------------------------------------------------------------------------
do $fixture$
declare
  v_m uuid; v_khan uuid; v_patel uuid; v_begum uuid; v_rate uuid;
begin
  insert into public.masjids (name) values ('TEST Taiyabah') returning id into v_m;
  update public._test_who set v = v_m::text where k = 'masjid';
  update public._test_who set v = 'admin'   where k = 'role';
  update public._test_who set v = gen_random_uuid()::text where k = 'uid';

  insert into public.madrasah_fee_rates (masjid_id, name, amount_p, is_default, sort)
  values (v_m, 'All classes', 1000, true, 1)
  on conflict (masjid_id, lower(btrim(name))) do update set amount_p = 1000, is_default = true
  returning id into v_rate;

  insert into public.madrasah_fee_rates (masjid_id, name, amount_p, is_default, sort)
  values (v_m, 'Hifz', 1400, false, 2)
  on conflict (masjid_id, lower(btrim(name))) do nothing;

  insert into public.madrasah_households (masjid_id, reference, name)
  values (v_m, 'MF-0001', 'Khan — 14 Blackburn Road') returning id into v_khan;
  insert into public.madrasah_households (masjid_id, reference, name)
  values (v_m, 'MF-0002', 'Patel — 3 Deane Road') returning id into v_patel;
  insert into public.madrasah_households (masjid_id, reference, name)
  values (v_m, 'MF-0003', 'Begum — 88 Derby Street') returning id into v_begum;

  insert into public.madrasah_guardians (masjid_id, household_id, full_name, email, is_primary)
  values (v_m, v_khan,  'Imran Khan',   'khan@example.test',  true),
         (v_m, v_patel, 'Sara Patel',   'patel@example.test', true);
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, phone, is_primary)
  values (v_m, v_begum, 'Nasreen Begum', '01204 000000', true);

  --  joined_on decides who is "first child". Deliberately inserted out of
  --  order so that a generator ranking by insertion order rather than by
  --  joined_on would produce the wrong discount and test 3 would catch it.
  insert into public.madrasah_pupils (masjid_id, first_name, last_name, joined_on, household_id)
  values (v_m, 'Zaynab', 'Khan',  '2025-09-01', v_khan),
         (v_m, 'Aisha',  'Khan',  '2023-09-01', v_khan),
         (v_m, 'Bilal',  'Khan',  '2024-09-01', v_khan),
         (v_m, 'Yusuf',  'Patel', '2024-09-01', v_patel),
         (v_m, 'Maryam', 'Begum', '2024-09-01', v_begum),
         (v_m, 'Nobody', 'Athome','2024-09-01', null);

  insert into public.madrasah_fee_periods (masjid_id, name, starts_on, ends_on, weeks)
  values (v_m, 'Autumn term 2026', '2026-09-07', '2026-12-18', 13);

  --  The three references above were written by hand so the tests can name
  --  them. The generator's sequence does not know that, so move it past them
  --  or the first save_madrasah_household() collides on MF-0001 — which is
  --  how tests 1 and 11 came to crash and vanish from the count on the first
  --  run of this file.
  perform setval('public.madrasah_household_ref_seq',
                 greatest(100, (select last_value from public.madrasah_household_ref_seq)));
end $fixture$;

-- ---------------------------------------------------------------------------
--  1. A family gets a reference, and it is the shape the office quotes
-- ---------------------------------------------------------------------------
do $t1$
declare v_r jsonb; v_ref text;
begin
  v_r := public.save_madrasah_household('{"name":"Ahmed — 2 Chorley Old Road"}'::jsonb);
  v_ref := v_r->>'reference';
  perform pg_temp.t('1  a new family is given an MF- reference',
                    v_ref ~ '^MF-[0-9]{4,6}$', v_ref);
  delete from public.madrasah_households where id = (v_r->>'id')::uuid;
end $t1$;

-- ---------------------------------------------------------------------------
--  2. Charges are raised for everyone who has a family, and nobody else
-- ---------------------------------------------------------------------------
do $t2$
declare v_p uuid; v_r jsonb;
begin
  select id into v_p from public.madrasah_fee_periods where name = 'Autumn term 2026';
  v_r := public.raise_madrasah_charges(v_p);

  perform pg_temp.t('2a five children with a family were charged',
                    (v_r->>'raised')::int = 5, v_r->>'raised');
  perform pg_temp.t('2b the child with no family was skipped AND reported',
                    (v_r->>'skipped_no_family')::int = 1, v_r->>'skipped_no_family');
  perform pg_temp.t('2c raising charges moved the term to issued',
                    (select status from public.madrasah_fee_periods where id = v_p) = 'issued',
                    (select status from public.madrasah_fee_periods where id = v_p));
end $t2$;

-- ---------------------------------------------------------------------------
--  3. Pressing it twice does not charge twice
--
--  Somebody will press it twice, because the first press takes a moment and
--  nothing appears to happen.
-- ---------------------------------------------------------------------------
do $t3$
declare v_p uuid; v_r jsonb; v_n int;
begin
  select id into v_p from public.madrasah_fee_periods where name = 'Autumn term 2026';
  v_r := public.raise_madrasah_charges(v_p);
  select count(*) into v_n from public.madrasah_charges where period_id = v_p;

  perform pg_temp.t('3a a second press raised nothing new',
                    (v_r->>'raised')::int = 0, v_r->>'raised');
  perform pg_temp.t('3b there are still exactly five charges',
                    v_n = 5, v_n::text);
end $t3$;

-- ---------------------------------------------------------------------------
--  4. The arithmetic, with no sibling rule set
--
--  13 weeks x £10 = £130 each. Khan has three children, so £390.
-- ---------------------------------------------------------------------------
do $t4$
declare v_bal bigint; v_one integer;
begin
  select net_p into v_one from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id
   where p.first_name = 'Yusuf';
  perform pg_temp.t('4a one child, 13 weeks at £10, is £130',
                    v_one = 13000, (v_one / 100.0)::text);

  select sum(net_p) into v_bal from public.madrasah_charges c
    join public.madrasah_households h on h.id = c.household_id
   where h.reference = 'MF-0001';
  perform pg_temp.t('4b three children with no discount is £390',
                    v_bal = 39000, (v_bal / 100.0)::text);
end $t4$;

-- ---------------------------------------------------------------------------
--  5. The sibling discount, applied to the right children
--
--  Rule: second child 25% off, third and later free.
--  Khan's children joined 2023 (Aisha), 2024 (Bilal), 2025 (Zaynab), so the
--  longest-standing pays full. Expected: £130 + £97.50 + £0 = £227.50.
--
--  The 25% of £130 is £32.50, which is 3250p exactly — deliberately chosen so
--  that a rounding error would show as a whole penny rather than hide.
-- ---------------------------------------------------------------------------
do $t5$
declare v_p uuid; v_m uuid; v_tot bigint; v_aisha int; v_bilal int; v_zaynab int;
begin
  select (select v from public._test_who where k='masjid')::uuid into v_m;
  perform public.save_madrasah_fee_setting('sibling_rule',
    '[{"from":2,"kind":"percent","value":25},{"from":3,"kind":"free"}]'::jsonb);

  --  Start the term again so the discount is applied at the moment of
  --  charging, which is how the office will actually do it.
  delete from public.madrasah_charges where masjid_id = v_m;
  select id into v_p from public.madrasah_fee_periods where name = 'Autumn term 2026';
  perform public.raise_madrasah_charges(v_p);

  select c.net_p into v_aisha from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Aisha';
  select c.net_p into v_bilal from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Bilal';
  select c.net_p into v_zaynab from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Zaynab';

  perform pg_temp.t('5a the longest-standing child pays in full (£130)',
                    v_aisha = 13000, (v_aisha / 100.0)::text);
  perform pg_temp.t('5b the second child pays 25% less (£97.50)',
                    v_bilal = 9750, (v_bilal / 100.0)::text);
  perform pg_temp.t('5c the third child is free',
                    v_zaynab = 0, (v_zaynab / 100.0)::text);

  select sum(c.net_p) into v_tot from public.madrasah_charges c
    join public.madrasah_households h on h.id = c.household_id
   where h.reference = 'MF-0001';
  perform pg_temp.t('5d the family bill is £227.50',
                    v_tot = 22750, (v_tot / 100.0)::text);

  --  A family of one is untouched by a sibling rule.
  select c.net_p into v_aisha from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Yusuf';
  perform pg_temp.t('5e an only child is unaffected by the sibling rule',
                    v_aisha = 13000, (v_aisha / 100.0)::text);
end $t5$;

-- ---------------------------------------------------------------------------
--  6. A child who has left stops counting towards a sibling position
--
--  The eldest leaves. The remaining two become first and second, so the bill
--  should go UP for one of them, not stay the same.
-- ---------------------------------------------------------------------------
do $t6$
declare v_m uuid; v_p uuid; v_bilal int; v_zaynab int;
begin
  select (select v from public._test_who where k='masjid')::uuid into v_m;
  update public.madrasah_pupils set left_on = '2026-08-31' where first_name = 'Aisha';

  delete from public.madrasah_charges where masjid_id = v_m;
  select id into v_p from public.madrasah_fee_periods where name = 'Autumn term 2026';
  perform public.raise_madrasah_charges(v_p);

  select c.net_p into v_bilal from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Bilal';
  select c.net_p into v_zaynab from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Zaynab';

  perform pg_temp.t('6a with the eldest gone, the next child pays in full',
                    v_bilal = 13000, (v_bilal / 100.0)::text);
  perform pg_temp.t('6b and the youngest moves from free to 25% off',
                    v_zaynab = 9750, (v_zaynab / 100.0)::text);
  perform pg_temp.t('6c a child who has left is not charged at all',
                    not exists (select 1 from public.madrasah_charges c
                                  join public.madrasah_pupils p on p.id = c.pupil_id
                                 where p.first_name = 'Aisha'), null);

  update public.madrasah_pupils set left_on = null where first_name = 'Aisha';
end $t6$;

-- ---------------------------------------------------------------------------
--  7. Money in, money back, and the balance
-- ---------------------------------------------------------------------------
do $t7$
declare v_h uuid; v_st jsonb; v_bal bigint;
begin
  select id into v_h from public.madrasah_households where reference = 'MF-0002';

  perform public.record_madrasah_payment(jsonb_build_object(
    'household_id', v_h, 'amount_p', 10000, 'method', 'bank',
    'bank_reference', 'MF-0002 PATEL'));

  v_st := public.madrasah_household_statement(v_h);
  perform pg_temp.t('7a £100 against a £130 bill leaves £30 owing',
                    (v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint = 3000,
                    (((v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint) / 100.0)::text);

  --  Overpay, then refund. A refund is a payment with a minus sign, so the
  --  same subtraction has to give the same answer as before the overpayment.
  perform public.record_madrasah_payment(jsonb_build_object(
    'household_id', v_h, 'amount_p', 5000, 'method', 'cash'));
  v_st := public.madrasah_household_statement(v_h);
  perform pg_temp.t('7b overpaying by £20 puts the family £20 in credit',
                    (v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint = -2000,
                    (((v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint) / 100.0)::text);

  perform public.record_madrasah_payment(jsonb_build_object(
    'household_id', v_h, 'amount_p', 2000, 'kind', 'refund', 'method', 'bank'));
  v_st := public.madrasah_household_statement(v_h);
  perform pg_temp.t('7c refunding the £20 brings the family back to nil',
                    (v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint = 0,
                    (((v_st->>'charged_p')::bigint - (v_st->>'paid_p')::bigint) / 100.0)::text);

  --  THE ONE THAT WOULD MATTER. A refund form that forgets the minus sign
  --  must not record money coming in.
  perform pg_temp.t('7d a refund was stored as a negative amount',
                    (select amount_p from public.madrasah_payments
                      where household_id = v_h and kind = 'refund') = -2000,
                    (select amount_p::text from public.madrasah_payments
                      where household_id = v_h and kind = 'refund'));
end $t7$;

-- ---------------------------------------------------------------------------
--  8. Waivers and discounts on a charge that exists
-- ---------------------------------------------------------------------------
do $t8$
declare v_c uuid; v_bad boolean; v_net int;
begin
  select c.id into v_c from public.madrasah_charges c
    join public.madrasah_pupils p on p.id = c.pupil_id where p.first_name = 'Maryam';

  --  A write-off has to say why. The trustees see the total.
  v_bad := false;
  begin
    perform public.adjust_madrasah_charge(jsonb_build_object('id', v_c, 'waived_p', 5000));
    v_bad := true;
  exception when others then null; end;
  perform pg_temp.t('8a a waiver with no reason is refused', not v_bad, null);

  perform public.adjust_madrasah_charge(jsonb_build_object(
    'id', v_c, 'waived_p', 5000, 'waiver_note', 'Hardship — agreed by trustees 12 Sept'));
  select net_p into v_net from public.madrasah_charges where id = v_c;
  perform pg_temp.t('8b a £50 waiver on a £130 bill leaves £80',
                    v_net = 8000, (v_net / 100.0)::text);

  --  More relief than there is bill would put the family in credit and drop
  --  them off the Outstanding screen — the error would hide itself.
  v_bad := false;
  begin
    perform public.adjust_madrasah_charge(jsonb_build_object(
      'id', v_c, 'waived_p', 99000, 'waiver_note', 'oops'));
    v_bad := true;
  exception when others then null; end;
  perform pg_temp.t('8c relief bigger than the bill is refused', not v_bad, null);
end $t8$;

-- ---------------------------------------------------------------------------
--  9. Reminders
-- ---------------------------------------------------------------------------
do $t9$
declare v_khan uuid; v_begum uuid; v_patel uuid; v_r jsonb;
begin
  insert into public.app_settings (key, value) values ('notify_url', 'http://localhost/notify')
    on conflict (key) do update set value = excluded.value;
  insert into public.app_settings (key, value) values ('notify_secret', 'test-secret')
    on conflict (key) do update set value = excluded.value;

  select id into v_khan  from public.madrasah_households where reference = 'MF-0001';
  select id into v_begum from public.madrasah_households where reference = 'MF-0003';
  select id into v_patel from public.madrasah_households where reference = 'MF-0002';

  v_r := public.send_madrasah_fee_reminders(array[v_khan, v_begum, v_patel]);

  perform pg_temp.t('9a the family that owes and has an email was written to',
                    (v_r->>'sent')::int = 1, v_r->>'sent');
  perform pg_temp.t('9b the family with only a phone number is reported, not sent',
                    (v_r->>'no_contact')::int = 1, v_r->>'no_contact');
  perform pg_temp.t('9c the family that owes nothing is left alone',
                    (v_r->>'nothing_owed')::int = 1, v_r->>'nothing_owed');

  v_r := public.send_madrasah_fee_reminders(array[v_khan]);
  perform pg_temp.t('9d pressing send again the same day sends nothing',
                    (v_r->>'too_soon')::int = 1, v_r->>'too_soon');

  --  THE DISCLOSURE TEST. Whatever was posted must not name a child.
  perform pg_temp.t('9e no child''s name left in an email about money',
                    not exists (
                      select 1 from net._sent s, public.madrasah_pupils p
                       where s.body::text ilike '%' || p.first_name || '%'),
                    (select string_agg(distinct p.first_name, ', ')
                       from net._sent s, public.madrasah_pupils p
                      where s.body::text ilike '%' || p.first_name || '%'));

  perform pg_temp.t('9f the family reference did go, so the parent can pay',
                    exists (select 1 from net._sent where body->>'reference' = 'MF-0001'), null);
end $t9$;

-- ---------------------------------------------------------------------------
--  10. A teacher gets nothing at all
--
--  The whole Fees section is marked ADMIN in the rail, but the rail is
--  cosmetic — admin/shell.js says so itself. This is the real gate.
-- ---------------------------------------------------------------------------
do $t10$
declare
  v_h uuid; v_fn text; v_blocked int := 0; v_total int := 0; v_leaked text := '';
begin
  select id into v_h from public.madrasah_households where reference = 'MF-0001';
  update public._test_who set v = 'madrasah' where k = 'role';   -- a teacher

  foreach v_fn in array array[
    'select public.madrasah_household_list(null)',
    'select public.madrasah_household_one(''' || v_h || ''')',
    'select public.madrasah_fee_balances(false, null)',
    'select public.madrasah_household_statement(''' || v_h || ''')',
    'select public.madrasah_fees_overview()',
    'select public.madrasah_fee_annual_report(null, null)',
    'select public.madrasah_fee_structure()',
    'select public.send_madrasah_fee_reminders(array[''' || v_h || ''']::uuid[])'
  ] loop
    v_total := v_total + 1;
    begin
      execute v_fn;
      v_leaked := v_leaked || split_part(split_part(v_fn, 'public.', 2), '(', 1) || ' ';
    exception when others then
      v_blocked := v_blocked + 1;
    end;
  end loop;

  perform pg_temp.t('10  a teacher is refused by all ' || v_total || ' fee functions',
                    v_blocked = v_total,
                    case when v_leaked = '' then null else 'leaked: ' || v_leaked end);

  update public._test_who set v = 'admin' where k = 'role';
end $t10$;

-- ---------------------------------------------------------------------------
--  11. Whoever the form ticks is the one we write to
-- ---------------------------------------------------------------------------
do $t11$
declare v_r jsonb; v_id uuid; v_who text; v_n int;
begin
  --  Mother listed first, father ticked. The naive implementation tries to
  --  hold two primaries at once and dies on "duplicate key".
  v_r := public.save_madrasah_household(jsonb_build_object(
    'name', 'Two parents',
    'guardians', jsonb_build_array(
      jsonb_build_object('full_name', 'The mother', 'email', 'm@example.test'),
      jsonb_build_object('full_name', 'The father', 'email', 'f@example.test',
                         'is_primary', true))));
  v_id := (v_r->>'id')::uuid;

  select full_name into v_who from public.madrasah_guardians
   where household_id = v_id and is_primary;
  select count(*) into v_n from public.madrasah_guardians
   where household_id = v_id and is_primary;

  perform pg_temp.t('11a the ticked parent is the one we write to', v_who = 'The father', v_who);
  perform pg_temp.t('11b exactly one of them is', v_n = 1, v_n::text);

  --  Nobody ticked: whoever was listed first.
  v_r := public.save_madrasah_household(jsonb_build_object(
    'id', v_id,
    'name', 'Two parents',
    'guardians', jsonb_build_array(
      jsonb_build_object('full_name', 'The mother', 'email', 'm@example.test'),
      jsonb_build_object('full_name', 'The father', 'email', 'f@example.test'))));
  select full_name into v_who from public.madrasah_guardians
   where household_id = v_id and is_primary;
  perform pg_temp.t('11c with nobody ticked, the first listed is used',
                    v_who = 'The mother', v_who);

  delete from public.madrasah_households where id = v_id;
end $t11$;

-- ---------------------------------------------------------------------------
--  12. The privilege gate in front of RLS
--
--  The thing the whole design rests on. See the header.
-- ---------------------------------------------------------------------------
do $t12$
declare v_t text; v_bad text := '';
begin
  foreach v_t in array array['madrasah_households', 'madrasah_guardians',
                             'madrasah_charges', 'madrasah_payments',
                             'madrasah_fee_rates', 'madrasah_fee_periods',
                             'madrasah_fee_settings', 'madrasah_fee_reminders'] loop
    if exists (select 1 from information_schema.role_table_grants
                where table_schema = 'public' and table_name = v_t
                  and grantee in ('anon', 'authenticated', 'public')) then
      v_bad := v_bad || v_t || ' ';
    end if;
    if exists (select 1 from pg_policies where schemaname='public' and tablename = v_t) then
      v_bad := v_bad || v_t || '(has a policy) ';
    end if;
  end loop;
  perform pg_temp.t('12  no fee table is reachable by anon or authenticated',
                    v_bad = '', nullif(v_bad, ''));
end $t12$;

-- ---------------------------------------------------------------------------
--  13. The annual report adds up to the same numbers as the screens
--
--  Two different queries over the same rows. If they ever disagree, one of
--  the two screens is lying to a trustee.
-- ---------------------------------------------------------------------------
do $t13$
declare v_rep jsonb; v_bal jsonb; v_sum bigint;
begin
  v_rep := public.madrasah_fee_annual_report('2026-01-01', '2026-12-31');
  v_bal := public.madrasah_fee_balances(true, null);

  select coalesce(sum((x->>'balance_p')::bigint), 0) into v_sum
    from jsonb_array_elements(v_bal) x;

  perform pg_temp.t('13a outstanding on the report matches the outstanding list',
                    (v_rep->>'outstanding_now_p')::bigint = v_sum,
                    (v_rep->>'outstanding_now_p') || ' vs ' || v_sum::text);

  perform pg_temp.t('13b charged = gross - discount - waived, on the report',
                    (v_rep->>'charged_p')::bigint
                      = (v_rep->>'gross_p')::bigint - (v_rep->>'discount_p')::bigint
                                                    - (v_rep->>'waived_p')::bigint,
                    v_rep->>'charged_p');

  perform pg_temp.t('13c the waiver from test 8 is itemised for the trustees',
                    jsonb_array_length(v_rep->'waivers') >= 1
                    and (v_rep->'waivers'->0->>'why') is not null,
                    (v_rep->'waivers'->0->>'why'));
end $t13$;

-- ---------------------------------------------------------------------------
--  14. A term that has been billed is frozen
-- ---------------------------------------------------------------------------
do $t14$
declare v_p uuid; v_bad boolean := false; v_weeks numeric;
begin
  select id into v_p from public.madrasah_fee_periods where name = 'Autumn term 2026';
  begin
    perform public.save_madrasah_fee_period(jsonb_build_object(
      'id', v_p, 'name', 'Autumn term 2026', 'starts_on', '2026-09-07',
      'ends_on', '2026-12-18', 'weeks', 12));
    v_bad := true;
  exception when others then null; end;

  select weeks into v_weeks from public.madrasah_fee_periods where id = v_p;
  perform pg_temp.t('14a changing the weeks of a billed term is refused', not v_bad, null);
  perform pg_temp.t('14b and the week count is untouched', v_weeks = 13, v_weeks::text);

  --  Renaming it is fine. Nothing is calculated from the name.
  perform public.save_madrasah_fee_period(jsonb_build_object(
    'id', v_p, 'name', 'Autumn 2026', 'starts_on', '2026-09-07',
    'ends_on', '2026-12-18', 'weeks', 13));
  perform pg_temp.t('14c but renaming it is allowed',
                    (select name from public.madrasah_fee_periods where id = v_p) = 'Autumn 2026',
                    (select name from public.madrasah_fee_periods where id = v_p));
end $t14$;

-- ---------------------------------------------------------------------------
--  15. A family with money against it cannot be quietly deleted
-- ---------------------------------------------------------------------------
do $t15$
declare v_h uuid; v_bad boolean := false;
begin
  select id into v_h from public.madrasah_households where reference = 'MF-0001';
  begin
    perform public.delete_madrasah_household(v_h);
    v_bad := true;
  exception when others then null; end;
  perform pg_temp.t('15  a family with children attached cannot be deleted', not v_bad, null);
end $t15$;

-- ---------------------------------------------------------------------------
--  16. Regressions found by review on 20 September. Each one was a real
--      defect in the first draft; each assertion was watched failing.
-- ---------------------------------------------------------------------------
do $t16$
declare
  v_m uuid := (select v from public._test_who where k='masjid')::uuid;
  v_h uuid; v_p uuid; v_c uuid; v_bad boolean; v_note text; v_off int;
begin
  select id into v_h from public.madrasah_households where reference = 'MF-0001';

  --  (a) THE RULE THAT APPLIES IS THE ONE WITH THE HIGHEST POSITION, not the
  --      one written last. The first version iterated the array as given and
  --      claimed in a comment that order did not matter, so a rule list of
  --      [2 = free, 3 = 25% off] made the third child pay MORE than the
  --      second — and the screen lets an administrator type exactly that.
  perform public.save_madrasah_fee_setting('sibling_rule',
    '[{"from":3,"kind":"percent","value":25},{"from":2,"kind":"free"}]'::jsonb);
  select p.id into v_p from public.madrasah_pupils p
    join public.madrasah_households hh on hh.id = p.household_id
   where hh.reference = 'MF-0001' and p.first_name = 'Bilal';
  v_off := public.madrasah_sibling_discount_p(v_h, v_p, 13000);
  perform pg_temp.t('16a the rule is applied in position order, not array order',
                    v_off = 13000, v_off::text);

  --  (b) A TEACHER CANNOT USE THE DISCOUNT FUNCTION AS AN ORACLE. It is
  --      arithmetic on two FORCE-RLS tables: a non-zero answer confirms a
  --      pupil belongs to a household, and the size of it leaks the rule.
  update public._test_who set v = 'madrasah' where k = 'role';
  v_bad := false;
  begin
    perform public.madrasah_sibling_discount_p(v_h, v_p, 13000);
    v_bad := true;
  exception when others then null; end;
  perform pg_temp.t('16b a teacher cannot ask what a family''s discount is', not v_bad, null);
  update public._test_who set v = 'admin' where k = 'role';

  --  (c) AN ABSENT KEY MEANS LEAVE IT ALONE. The waiver form sends only the
  --      waiver fields, and this used to wipe "Sibling discount" off the
  --      charge — leaving an unexplained discount in the annual report, which
  --      is the exact thing the compulsory waiver reason exists to prevent.
  select c.id into v_c from public.madrasah_charges c
    join public.madrasah_pupils pp on pp.id = c.pupil_id
   where pp.first_name = 'Zaynab';
  perform public.adjust_madrasah_charge(jsonb_build_object(
    'id', v_c, 'discount_p', 3250, 'discount_note', 'Sibling discount'));
  perform public.adjust_madrasah_charge(jsonb_build_object(
    'id', v_c, 'waived_p', 1000, 'waiver_note', 'Hardship'));
  select discount_note into v_note from public.madrasah_charges where id = v_c;
  perform pg_temp.t('16c writing off part of a charge keeps the discount''s reason',
                    v_note = 'Sibling discount', coalesce(v_note, 'null'));

  --  (d) A CHARGE CANNOT BE STAMPED WITH A CHILD FROM A DIFFERENT FAMILY.
  --      The foreign key only required the pupil to exist somewhere, so the
  --      statement would have shown another family's child on this account.
  select p.id into v_p from public.madrasah_pupils p
    join public.madrasah_households hh on hh.id = p.household_id
   where hh.reference = 'MF-0002';
  v_bad := false;
  begin
    perform public.add_madrasah_charge(jsonb_build_object(
      'household_id', v_h, 'pupil_id', v_p,
      'description', 'Admission fee', 'gross_p', 2000));
    v_bad := true;
  exception when others then null; end;
  perform pg_temp.t('16d a charge cannot name a child from another family', not v_bad, null);

  --  (e) "LAST REMINDED" ON THE SCREEN AND "TOO SOON" IN THE SENDER MUST USE
  --      THE SAME ROWS. Every press logs the families it did NOT write to as
  --      well, so counting those made the screen say a family had been
  --      reminded yesterday, put them in the "will be skipped" count of the
  --      confirmation — and then email them anyway.
  --  MF-0003 is the right family to ask about: test 9 logged it as
  --  no_contact and never sent to it. MF-0001 was genuinely emailed, so
  --  asserting against that one would have been a test of nothing — it was,
  --  on the first run of this block, and it failed for the right reason.
  perform pg_temp.t('16e a family we could not reach does not count as reminded',
                    (select x->>'last_reminded_at'
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0003') is null,
                    (select coalesce(x->>'last_reminded_at', 'null')
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0003'));
  perform pg_temp.t('16e2 CONTROL — a family we did email does count',
                    (select x->>'last_reminded_at'
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0001') is not null, null);

  --  (f) "CAN EMAIL" MEANS THE PRIMARY CONTACT HAS ONE. A family whose
  --      primary has only a telephone number and whose second parent has an
  --      email was flagged green, was tickable, survived the "only families
  --      we can email" filter — and came back no_contact.
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, email, is_primary)
  select v_m, id, 'Second parent', 'second@example.test', false
    from public.madrasah_households where reference = 'MF-0003';
  perform pg_temp.t('16f a second parent''s email does not make a family contactable',
                    (select (x->>'can_email')::boolean
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0003') = false,
                    (select x->>'can_email'
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0003'));

  --  (g) A BILLED TERM CAN STILL BE RENAMED AND CLOSED. The screen omits the
  --      frozen fields, the insert evaluated them to NULL against NOT NULL
  --      columns, and the save died on a raw constraint message — so a term
  --      could never be closed once it had been billed, which is exactly when
  --      anybody would want to.
  v_bad := false;
  begin
    perform public.save_madrasah_fee_period(jsonb_build_object(
      'id', (select id from public.madrasah_fee_periods where masjid_id = v_m limit 1),
      'name', 'Autumn 2026', 'status', 'closed'));
  exception when others then v_bad := true; end;
  perform pg_temp.t('16g a billed term can still be closed', not v_bad, null);
  perform pg_temp.t('16h and closing it did not change its week count',
                    (select weeks from public.madrasah_fee_periods
                      where masjid_id = v_m limit 1) = 13,
                    (select weeks::text from public.madrasah_fee_periods
                      where masjid_id = v_m limit 1));

  --  (i) THE ANNUAL REPORT'S COLUMN ADDS UP TO THE TOTAL UNDER IT. Every row
  --      used to sum all of a term's charges while the headline was filtered
  --      to the date range, and charges belonging to no term appeared in the
  --      total and in no row.
  perform pg_temp.t('16i the by-term column sums to the report total',
                    (select coalesce(sum((x->>'charged_p')::bigint), 0)
                       from jsonb_array_elements(
                         public.madrasah_fee_annual_report('2026-01-01','2026-12-31')->'by_period') x)
                    = (public.madrasah_fee_annual_report('2026-01-01','2026-12-31')->>'charged_p')::bigint,
                    (select coalesce(sum((x->>'charged_p')::bigint), 0)::text
                       from jsonb_array_elements(
                         public.madrasah_fee_annual_report('2026-01-01','2026-12-31')->'by_period') x)
                    || ' vs ' || (public.madrasah_fee_annual_report('2026-01-01','2026-12-31')->>'charged_p'));
end $t16$;

-- ---------------------------------------------------------------------------
--  17. "Sent" has to mean sent — migration 072
--
--  071 queued a message and wrote 'sent' on the next line. net.http_post is
--  fire-and-forget, so it could not have known. Worse, 'sent' is what starts
--  the seven-day lock: a family whose message failed was recorded as chased,
--  could not be chased again for a week, and had never been written to.
-- ---------------------------------------------------------------------------
do $t17$
declare
  v_m uuid := (select v from public._test_who where k='masjid')::uuid;
  v_h uuid; v_r jsonb; v_req bigint; v_out text; v_err text;
begin
  select id into v_h from public.madrasah_households where reference = 'MF-0001';
  delete from public.madrasah_fee_reminders where masjid_id = v_m;

  --  (a) Queued, not sent, and the request id is remembered.
  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  select outcome, request_id into v_out, v_req
    from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  perform pg_temp.t('17a a reminder is recorded queued, not sent', v_out = 'queued', v_out);
  perform pg_temp.t('17b and it remembers which request it was', v_req is not null,
                    coalesce(v_req::text, 'null'));

  --  (b) A good answer resolves it to sent.
  insert into net._http_response (id, status_code, content)
  values (v_req, 200, '{"ok":true}')
  on conflict (id) do update set status_code = 200;
  perform public.reconcile_madrasah_fee_reminders();
  select outcome into v_out from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  perform pg_temp.t('17c a 200 from the mail server resolves it to sent', v_out = 'sent', v_out);

  --  (c) A bad answer resolves it to failed, WITH THE REASON — and a failed
  --      reminder can be sent again at once. If it could not, knowing about
  --      the failure would be useless.
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from net._http_response;
  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  select request_id into v_req from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  insert into net._http_response (id, status_code, content)
  values (v_req, 401, 'Unauthorized');
  perform public.reconcile_madrasah_fee_reminders();
  select outcome, error into v_out, v_err from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  perform pg_temp.t('17d a 401 resolves it to failed', v_out = 'failed', v_out);
  perform pg_temp.t('17e and the reason is recorded, not just the fact',
                    v_err is not null and v_err like '%401%', coalesce(v_err, 'null'));

  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  perform pg_temp.t('17f a family whose message failed can be written to again at once',
                    (v_r->>'sent')::int = 1, v_r::text);

  --  (d) But one still waiting for an answer holds the lock.
  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  perform pg_temp.t('17g a family whose message is still queued does not get a second',
                    (v_r->>'too_soon')::int = 1, v_r::text);

  --  (e) THE SCREEN AND THE SENDER HAVE TO AGREE. madrasah_fee_balances'
  --      "last reminded" counts queued and sent, exactly as the sender does.
  --      When it counted only 'sent' the screen offered the office a family
  --      the database would then refuse.
  perform pg_temp.t('17h the screen sees a queued message as a reminder',
                    (select x->>'last_reminded_at'
                       from jsonb_array_elements(public.madrasah_fee_balances(true, null)) x
                      where x->>'reference' = 'MF-0001') is not null, null);

  --  (f) An answer that never comes is written off rather than left waiting
  --      for ever. pg_net sweeps its own responses within hours.
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from net._http_response;
  insert into public.madrasah_fee_reminders
    (masjid_id, household_id, balance_p, outcome, request_id, sent_at)
  values (v_m, v_h, 1000, 'queued', 999999, now() - interval '7 hours');
  perform public.reconcile_madrasah_fee_reminders();
  select outcome, error into v_out, v_err from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  perform pg_temp.t('17i a message with no answer after six hours is written off',
                    v_out = 'failed', v_out);
  perform pg_temp.t('17j and it says the masjid cannot tell, rather than claiming it failed',
                    v_err like '%no way to tell%', coalesce(v_err, 'null'));

  --  (g) A message still young enough to get an answer is left alone.
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  insert into public.madrasah_fee_reminders
    (masjid_id, household_id, balance_p, outcome, request_id, sent_at)
  values (v_m, v_h, 1000, 'queued', 999998, now() - interval '2 minutes');
  perform public.reconcile_madrasah_fee_reminders();
  select outcome into v_out from public.madrasah_fee_reminders
   where household_id = v_h order by sent_at desc limit 1;
  perform pg_temp.t('17k a message sent two minutes ago is still waiting, not written off',
                    v_out = 'queued', v_out);

  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from net._http_response;
end $t17$;

-- ---------------------------------------------------------------------------
--  Report
-- ---------------------------------------------------------------------------
\echo ''
\echo '  _test_fees.sql'
\echo '  --------------'
select case when ok then '  ok    ' else '  FAIL  ' end || n
         || coalesce('   [' || got || ']', '') as result from _t order by n;
\echo ''
select count(*) filter (where ok)     as passed,
       count(*) filter (where not ok) as failed,
       count(*)                       as total
  from _t;

--  A DO BLOCK THAT RAISES RECORDS NOTHING AND LOOKS EXACTLY LIKE A PASS.
--  On the first run of this file two blocks died on a duplicate reference,
--  four assertions never ran, and the report said 37 of 37. `portal_test.py`
--  was bitten by the same shape in September. The expected count is written
--  down here so that a suite which quietly stops running says so.
do $expected$
declare v_n int; v_want constant int := 62;
begin
  select count(*) into v_n from _t;
  if v_n <> v_want then
    raise warning 'SUITE INCOMPLETE: % assertions ran, % expected. A test block errored before recording anything — scroll up for the first ERROR line. Do not read the pass count above as a pass.', v_n, v_want;
  end if;
end $expected$;

-- ---------------------------------------------------------------------------
--  Tidy up. Money tables first — they RESTRICT deletion of the family they
--  belong to, which is test 15's whole point.
-- ---------------------------------------------------------------------------
do $cleanup2$
declare v_m uuid := (select v from public._test_who where k='masjid')::uuid;
begin
  if v_m is null then return; end if;
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from public.madrasah_payments       where masjid_id = v_m;
  delete from public.madrasah_charges        where masjid_id = v_m;
  delete from public.madrasah_pupils         where masjid_id = v_m;
  delete from public.madrasah_guardians      where masjid_id = v_m;
  delete from public.madrasah_households     where masjid_id = v_m;
  delete from public.madrasah_fee_periods    where masjid_id = v_m;
  delete from public.madrasah_fee_rates      where masjid_id = v_m;
  delete from public.madrasah_fee_settings   where masjid_id = v_m;
  delete from public.masjids                 where id = v_m;
  update public._test_who set v = null   where k = 'masjid';
  update public._test_who set v = 'none' where k = 'role';
end $cleanup2$;
