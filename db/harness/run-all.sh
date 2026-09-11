#!/bin/bash
# Runs every SQL suite in db/ against a database built to the shape it expects.
#
# The profile column is the whole point of this file: a suite silently stops
# running when a later migration changes the shape underneath it, and nobody
# notices, because the folder still looks covered. If you add a suite, add it
# here. If a suite errors before printing a count, that is a FAILURE, not a
# quirk — read the error.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
S="$(cd "$here/.." && pwd)"

suites="
_test_admissions:full
_test_courses:full
_test_nikah:full
_test_nikah_fee:full
_test_deposit:full
_test_paid_is_booked:full
_test_two_step:full
_test_weekly_digest:full
_test_unpaid_not_booked:full
_test_retention:retention
_test_whole_day_hire:hall
_test_course_admin:admin
"

tp=0; tf=0; bad=0
printf '%-26s %-10s %8s %8s\n' SUITE PROFILE PASSED FAILED
printf '%.0s-' {1..56}; echo
for entry in $suites; do
  name="${entry%%:*}"; profile="${entry##*:}"
  db="t_run_$(echo "$name" | tr -dc 'a-z_')"
  bash "$here/build.sh" "$db" "$profile" >/dev/null 2>&1
  out=$(su postgres -c "psql -q -X -d $db -f $S/$name.sql" 2>&1)
  line=$(echo "$out" | grep -A2 'passed | failed' | tail -1)
  p=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$1); print $1}')
  f=$(echo "$line" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
  if [ -z "${p:-}" ]; then
    printf '%-26s %-10s %8s %8s   <-- DID NOT REPORT\n' "$name" "$profile" - -
    echo "$out" | grep -m1 'ERROR:' | sed 's/^/      /'
    bad=$((bad+1))
  else
    printf '%-26s %-10s %8s %8s%s\n' "$name" "$profile" "$p" "$f" \
      "$( [ "$f" != 0 ] && echo '   <-- FAILURES' )"
    tp=$((tp+p)); tf=$((tf+f))
  fi
  su postgres -c "dropdb --if-exists $db" >/dev/null 2>&1
done
printf '%.0s-' {1..56}; echo
printf '%-37s %8s %8s\n' TOTAL "$tp" "$tf"
[ "$bad" -gt 0 ] && echo "$bad suite(s) did not run at all — that is worse than a failure."
[ "$tf" -eq 0 ] && [ "$bad" -eq 0 ] && echo "All green."
