# The local test harness

**This folder is why the SQL suites can still be run in a year.**

Every `_test_*.sql` file in `db/` needs a *particular* database — a specific set
of migrations, applied in a specific order, against a role that is **not** a
superuser (a superuser ignores RLS, so testing as one proves nothing).

Until 8 September 2026 the scripts that built those databases lived only in a
scratch directory on one machine. Three suites had quietly stopped running —
`_test_two_step.sql` had been dead since migration 016 made `reference` NOT
NULL, and nobody could tell, because the folder still looked covered. **A suite
nobody can run is indistinguishable from a suite that passes.** They are in the
repository now for that reason.

## Running everything

```bash
cd db/harness
./run-all.sh                      # expects postgres running locally
```

It prints one line per suite and a total. Any non-zero failure count, or any
suite that errors before reporting, is a real problem — including "the suite is
stale", which is the most common one.

## What it needs

- PostgreSQL 16 running locally, with `su postgres` available
- The sister repo `taiyabah-madrasah-db` checked out beside this one, for
  migrations 001–007. Override with `MADRASAH_DB=/path/to/it`.
- **No network, no Supabase, no Stripe.** `pg_net` and `pg_cron` are stubbed;
  `net.http_post` records into `net._sent` instead of sending. Nothing here can
  touch production, which is the point.

## Never run a `_test_*.sql` file against Supabase

They create roles, move ownership, insert fixtures and delete rows.
