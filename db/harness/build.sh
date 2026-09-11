#!/bin/bash
# build.sh <dbname> <profile>
#
# Builds a throwaway local database to the shape a given suite expects.
# Profiles exist because the suites were written at different times against
# different migration sets; the profile name is recorded in each suite header.
set -e
db=$1
profile=$2
here="$(cd "$(dirname "$0")" && pwd)"
S="$(cd "$here/.." && pwd)"                                   # this repo's db/
M="${MADRASAH_DB:-$(cd "$S/../.." && pwd)/taiyabah-madrasah-db}"

[ -d "$M" ] || { echo "madrasah-db not found at $M — set MADRASAH_DB" >&2; exit 1; }

psqlq(){ su postgres -c "psql -q -v ON_ERROR_STOP=1 -d $db -f $1" >/dev/null 2>&1; }

# Send a whole file as ONE query string, which is what the Supabase SQL editor
# does. `psql -f` reads it line by line and interprets backslash meta-commands
# itself, so it silently tolerates things the editor rejects. That difference
# cost a failed migration once.
editor(){ su postgres -c "psql -q -X -d $db -c \"\$(cat $1)\"" >/dev/null 2>&1 || true; }

su postgres -c "dropdb --if-exists $db; createdb $db" >/dev/null 2>&1

# --- foundation: the sister repo, 001..006 (007 needs pg_cron) --------------
for f in _test_supabase_stub 001_foundation 002_grants 003_hall_bookings \
         004_hall_office_role 005_availability_by_hall 006_halls_and_kitchen; do
  psqlq "$M/$f.sql"
done

# One admin who has actually passed two-step, so 011's policies have somebody
# to be satisfied by.
su postgres -c "psql -q -d $db -c \"
insert into auth.users (id,email) values ('11111111-1111-1111-1111-111111111111','yameen@example.test');
insert into public.user_roles (user_id,role) values ('11111111-1111-1111-1111-111111111111','admin');
insert into auth.mfa_factors (user_id,status) values ('11111111-1111-1111-1111-111111111111','verified');\"" >/dev/null 2>&1

# --- stubs for the two extensions that cannot exist locally ----------------
# net.http_post records instead of sending, so a test can read back exactly
# what would have gone over the wire. cron.schedule is a no-op.
su postgres -c "psql -q -X -d $db" >/dev/null 2>&1 <<'SQL'
create schema if not exists net;
create table if not exists net._sent(url text, body jsonb, headers jsonb, at timestamptz default now());
create or replace function net.http_post(url text, body jsonb default '{}'::jsonb,
    params jsonb default '{}'::jsonb, headers jsonb default '{}'::jsonb,
    timeout_milliseconds int default 5000)
returns bigint language plpgsql as $f$
begin insert into net._sent(url, body, headers) values (url, body, headers); return 1; end$f$;
create schema if not exists cron;
create or replace function cron.schedule(j text, s text, c text)
returns bigint language sql as $f$ select 1::bigint $f$;
SQL

[ "$profile" = "foundation" ] && exit 0

# --- a booking taken under the PRE-014 model, for a date now past ----------
# The constraint has to come off to insert it, which is exactly what the
# calendar did by being three weeks earlier. Suites that prove the migration
# path need this row to exist.
case "$profile" in
  hall|deposit|retention|full)
su postgres -c "psql -q -X -d $db" >/dev/null 2>&1 <<'SQL'
alter table public.hall_bookings drop constraint date_not_past;
insert into public.hall_bookings
  (created_at, booking_date, session_slot, hall, kitchen, first_name, last_name, address, phone, status)
-- A FRIDAY, always. This used to be `current_date - interval '10 days'`,
-- which lands on a different weekday every day of the week — and the point of
-- the fixture is that ONE HALL ON A FRIDAY is a combination the current price
-- list does not sell, so there is no rate to backfill it with. Run on the
-- wrong day it became a weekday booking with a perfectly good £350 rate, and
-- _test_paid_is_booked failed for a reason that had nothing to do with the
-- code. A fixture whose meaning depends on what day you run it is not a
-- fixture.
values (now() - interval '12 days',
        current_date - ((extract(dow from current_date)::int + 2) % 7) - 7,
        'evening', '2', false, 'Old', 'Booking', '4 Mill Street', '07700900111', 'confirmed');
alter table public.hall_bookings
  add constraint date_not_past check (booking_date >= (now() at time zone 'Europe/London')::date) not valid;
SQL
  ;;
esac

case "$profile" in
  hall)      list="014_whole_day_hire" ;;
  admin)     list="008_admissions 009_courses 010_nikah_requests 011_require_two_step 013_course_admin 011_require_two_step" ;;
  retention) list="008_admissions 009_courses 010_nikah_requests 011_require_two_step 013_course_admin 014_whole_day_hire 015_retention 011_require_two_step" ;;
  deposit|full) list="008_admissions 009_courses 010_nikah_requests 011_require_two_step 013_course_admin 014_whole_day_hire 015_retention 016_deposit_holds_the_date 017_paid_is_booked 018_nikah_fee_online 019_weekly_digest 020_digest_auth_header 021_unpaid_is_not_booked 011_require_two_step" ;;
  *) echo "unknown profile: $profile" >&2; exit 1 ;;
esac

for f in $list; do editor "$S/$f.sql"; done
