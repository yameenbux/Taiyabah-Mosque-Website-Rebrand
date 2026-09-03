-- ===========================================================================
--  _test_nikah.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--  Ownership moves to a NOSUPERUSER NOBYPASSRLS role first — a superuser
--  ignores RLS, so testing as one proves nothing about production.
-- ===========================================================================
\set ON_ERROR_STOP on
do $$ begin if not exists (select 1 from pg_roles where rolname='app_owner')
  then create role app_owner nosuperuser nobypassrls login; end if; end $$;
alter table public.nikah_requests owner to app_owner;
alter sequence public.nikah_reference_seq owner to app_owner;
alter function public.request_nikah_date(jsonb)        owner to app_owner;
alter function public.purge_old_nikah_requests(int)    owner to app_owner;
grant insert on public.admin_audit to app_owner;
grant usage, select on sequence public.admin_audit_id_seq to app_owner;
grant usage on schema public to anon, authenticated, app_owner;

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated, app_owner;
create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,60)); end; end $$;
create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,80)); end; end $$;
create or replace function pg_temp.req(d text, email text, extra jsonb default '{}'::jsonb)
returns jsonb language plpgsql as $$ begin
  return public.request_nikah_date(
    jsonb_build_object('preferred_date',d,'slot','after_zuhr','preferred_time','13:30',
      'contact_name','A Person','contact_role','groom','contact_phone','07700900123',
      'contact_email',email,'privacy_accepted',true) || extra); end $$;

-- 1. anon may only call the function
set role anon;
select pg_temp.efail('anon cannot read requests','select * from public.nikah_requests');
select pg_temp.efail('anon cannot insert directly',
  $q$insert into public.nikah_requests(reference,preferred_date,contact_name,contact_role,
     contact_phone,contact_email,privacy_accepted,time_flexible,preferred_time)
     values('X',current_date+10,'a','groom','07','a@b.co',true,false,'14:00')$q$);
select pg_temp.efail('anon cannot update a status',
  'update public.nikah_requests set status = ''confirmed''');
select pg_temp.efail('anon cannot delete','delete from public.nikah_requests');
reset role;

-- 2. a normal request works, and comes back with a reference
set role anon;
do $$ declare res jsonb; begin
  res := pg_temp.req((current_date+30)::text,'couple1@example.com');
  insert into r select 'a request returns a reference', left(res->>'reference',3)='NK-', res->>'reference';
  insert into r select 'the requested date comes back',
    (res->>'preferred_date')::date = current_date+30, res->>'preferred_date';
end $$;
select pg_temp.eok('an alternative date is accepted',
  format($q$select pg_temp.req(%L,'couple2@example.com',
    jsonb_build_object('alternative_date',%L,'guests_estimate','120','notes','Saturday would suit us better'))$q$,
    (current_date+40)::text, (current_date+47)::text));
select pg_temp.eok('flexible is accepted without a prayer',
  format($q$select public.request_nikah_date(jsonb_build_object(
    'preferred_date',%L,'slot','flexible','time_flexible',true,'contact_name','B',
    'contact_role','bride','contact_phone','07','contact_email','couple3@example.com',
    'privacy_accepted',true))$q$, (current_date+50)::text));
reset role;

-- 3. the things that must be refused
set role anon;
select pg_temp.efail('a date in the past is refused',
  format($q$select pg_temp.req(%L,'past@example.com')$q$, (current_date-1)::text));
select pg_temp.efail('more than a year ahead is refused',
  format($q$select pg_temp.req(%L,'far@example.com')$q$, (current_date+400)::text));
select pg_temp.efail('no slot chosen is refused',
  format($q$select public.request_nikah_date(jsonb_build_object(
    'preferred_date',%L,'contact_name','C','contact_role','groom','contact_phone','07',
    'contact_email','notime@example.com','privacy_accepted',true))$q$, (current_date+25)::text));

-- the two-week notice period
select pg_temp.efail('inside the two-week notice period is refused',
  format($q$select pg_temp.req(%L,'soon@example.com')$q$, (current_date+13)::text));
select pg_temp.eok('exactly fourteen days ahead is accepted',
  format($q$select pg_temp.req(%L,'exactly14@example.com')$q$, (current_date+14)::text));

-- the Saturday-only slot
select pg_temp.efail('the 11am slot is refused on a weekday',
  format($q$select pg_temp.req(%L,'sat1@example.com',
    jsonb_build_object('slot','saturday_11','preferred_time','11:00'))$q$,
    (date_trunc('week', current_date + 21) + interval '2 days')::date::text));
select pg_temp.eok('the 11am slot is accepted on a Saturday',
  format($q$select pg_temp.req(%L,'sat2@example.com',
    jsonb_build_object('slot','saturday_11','preferred_time','11:00'))$q$,
    (date_trunc('week', current_date + 21) + interval '5 days')::date::text));
select pg_temp.efail('an unknown slot is refused',
  format($q$select pg_temp.req(%L,'slot@example.com',
    jsonb_build_object('slot','after_tahajjud'))$q$, (current_date+25)::text));
select pg_temp.efail('flexible flag must match the flexible slot',
  format($q$select pg_temp.req(%L,'mismatch@example.com',
    jsonb_build_object('slot','flexible'))$q$, (current_date+25)::text));
select pg_temp.efail('the privacy box must be ticked',
  format($q$select public.request_nikah_date(jsonb_build_object(
    'preferred_date',%L,'preferred_time','14:00','contact_name','C','contact_role','groom',
    'contact_phone','07','contact_email','nopriv@example.com','privacy_accepted',false))$q$,
    (current_date+25)::text));
select pg_temp.efail('a bad email is refused',
  format($q$select pg_temp.req(%L,'not-an-email')$q$, (current_date+25)::text));
select pg_temp.efail('an unknown contact role is refused',
  format($q$select pg_temp.req(%L,'role@example.com',
    jsonb_build_object('contact_role','wedding planner'))$q$, (current_date+25)::text));
select pg_temp.efail('the same email cannot request the same date twice',
  format($q$select pg_temp.req(%L,'couple1@example.com')$q$, (current_date+30)::text));
select pg_temp.eok('the same email CAN request a different date',
  format($q$select pg_temp.req(%L,'couple1@example.com')$q$, (current_date+31)::text));
reset role;

-- 4. two different couples may ask for the same day — the office decides
set role anon;
select pg_temp.eok('two couples may request the same date',
  format($q$select pg_temp.req(%L,'couple9@example.com')$q$, (current_date+30)::text));
reset role;

-- 5. admin workflow
set role authenticated; set app.is_admin='on';
insert into r select 'admin can read requests', count(*) >= 5, count(*)::text from public.nikah_requests;
select pg_temp.eok('admin can confirm a request',
  $q$update public.nikah_requests set status='confirmed', agreed_date=preferred_date
     where contact_email='couple1@example.com'$q$);
select pg_temp.efail('admin cannot rewrite the requested date',
  'update public.nikah_requests set preferred_date = current_date + 999');
reset role;
set role authenticated; set app.is_admin='off';
insert into r select 'non-admin reads nothing', count(*)=0, count(*)::text from public.nikah_requests;
select pg_temp.efail('non-admin cannot purge','select public.purge_old_nikah_requests(12)');
reset role;

-- 6. a withdrawn request frees the same date for the same person
set role authenticated; set app.is_admin='on';
update public.nikah_requests set status='withdrawn'
 where contact_email='couple9@example.com';
reset role;
set role anon;
select pg_temp.eok('re-requesting after withdrawal is allowed',
  format($q$select pg_temp.req(%L,'couple9@example.com')$q$, (current_date+30)::text));
reset role;

\echo ''
\echo '================ NIKAH REQUEST RESULTS ================'
select case when ok then 'PASS' else 'FAIL' end as res, name, detail from r order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from r;
