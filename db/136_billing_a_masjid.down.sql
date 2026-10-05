-- 136 down. Additive, so this restores the database exactly.
-- Order matters: functions first, then the tables they read, then the sequence.
--
-- A WORD OF WARNING. Dropping these tables destroys the invoice ledger, which
-- is an accounting record. If any invoice has been sent to a real masjid, export
-- it before running this.
drop function if exists public.billing_overview();
drop function if exists public.masjid_billing_summary(text);
drop function if exists public.invoice_void(text, text);
drop function if exists public.invoice_mark_paid(text, jsonb);
drop function if exists public.invoice_send(text, date);
drop function if exists public.invoice_raise(text, jsonb);
drop function if exists public.billing_set(text, jsonb);
drop function if exists public.invoice_total_p(uuid);
drop table if exists public.invoice_lines;
drop table if exists public.invoices;
drop table if exists public.masjid_billing;
drop sequence if exists public.invoice_number_seq;
