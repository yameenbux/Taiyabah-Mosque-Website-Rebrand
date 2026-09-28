--  =====================================================================
--  083 - 'not_yet_told' IS A REAL OUTCOME
--  27 September 2026
--  =====================================================================
--
--  082 taught send_madrasah_fee_reminders() to refuse a family that has not
--  been told the privacy notice exists, and to record the refusal as
--  outcome = 'not_yet_told' - exactly like the 'no_contact' and 'too_soon'
--  refusals beside it.
--
--  madrasah_fee_reminders has a CHECK constraint listing the outcomes it
--  accepts, and 'not_yet_told' was not one of them. So the new branch threw a
--  constraint violation instead of recording a refusal, and because the whole
--  send runs in one statement, ONE untold family would have aborted the
--  ENTIRE BATCH. Nothing would have been sent to anybody and the office would
--  have been handed a constraint error.
--
--  FOUND BY RUNNING IT - against a real family, with a real balance, as a
--  real administrator, in a transaction that rolled back. It could not have
--  been found any other way: the function is correct, the guard is correct,
--  and the table disagreed with both. Reading the code back would have shown
--  nothing wrong.
--
--  The fifth time on this system that the check which mattered was the one
--  that exercised the path rather than inspected it.

alter table public.madrasah_fee_reminders
  drop constraint if exists madrasah_reminder_outcome_valid;

alter table public.madrasah_fee_reminders
  add constraint madrasah_reminder_outcome_valid
  check (outcome = any (array[
    'queued',        -- handed to the mail provider, not yet confirmed
    'sent',          -- the provider accepted it
    'failed',        -- the provider refused it, with a reason
    'no_contact',    -- nobody on the family has an email address
    'too_soon',      -- written to within the last seven days
    'nothing_owed',  -- the balance was already clear when send was pressed
    'not_yet_told'   -- 082: the family has not been told the privacy notice
                     -- exists, so they are not written to about money
  ]));

comment on constraint madrasah_reminder_outcome_valid
  on public.madrasah_fee_reminders is
  'Every outcome the sender can record. Adding a branch to send_madrasah_fee_reminders without adding its outcome here aborts the whole batch, not just that family.';

--  PROVED, after this constraint was widened, against a real family in a
--  rolled-back transaction:
--
--    before being told : [{... "outcome": "not_yet_told"}]   nothing sent
--    recorded          : {"how": "letter", "recorded": 1, "skipped": 0}
--    after being told  : [{... "outcome": "queued"}]
--
--  Nothing was left behind: no charge, no reminder row, no queued email.
