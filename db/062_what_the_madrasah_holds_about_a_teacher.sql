-- ===========================================================================
--  062_what_the_madrasah_holds_about_a_teacher.sql
--  18 September 2026
--
--  From the masjid's own teacher record sheet, so the Staff screen stops
--  saying "Nothing on file" about people it has a file on. 20 of the 40 now
--  carry a real DBS issue date, which takes the picture from
--
--      40 nothing on file        ->      19 valid
--                                          1 overdue
--                                         20 nothing on file
--
--  ---------------------------------------------------------------------------
--  FOUR FIELDS ON THAT SHEET ARE DELIBERATELY NOT HERE, decided with the masjid
--  ---------------------------------------------------------------------------
--
--    DBS certificate number   052 already ruled on this in writing - "the one
--                             field that would hurt to leak and the one no
--                             screen needs". The number does not prove a check
--                             happened; the issue date and the Update Service
--                             do. It is only useful to somebody impersonating
--                             the teacher. 24 of 40 populated.
--
--    National Insurance no.   a lifelong identifier and the single most useful
--                             field there is for identity fraud. Payroll needs
--                             it; a madrasah register does not. 3 of 40.
--
--    Bank account details     belong wherever the masjid actually pays people,
--                             behind that system's controls. 1 of 40.
--
--    Gender                   the madrasah already records which SIDE somebody
--                             teaches, which is the operational fact. The
--                             sheet's own gender column has at least one
--                             obvious error in it, which rather makes the
--                             point about carrying a field nothing reads.
--
--  There is a check at the foot of this file that fails if any of them ever
--  appears, so adding one is a decision somebody has to take deliberately
--  rather than a column that quietly arrives.
--
--  ---------------------------------------------------------------------------
--  ONE THING THE IMPORT CAUGHT, WORTH REPEATING
--  ---------------------------------------------------------------------------
--  The PDF's two columns collapse into single lines in its text layer, so
--  "Mobile: 07442 465 456 Start Date: N/A" is ONE line. A naive \S+ capture
--  took "07442" - and where the mobile was blank it took the word "Start" from
--  the next column and stored that as a telephone number. Every number is now
--  captured up to the right-hand column's label and then checked for 10 to 13
--  digits before it is written. Nothing that fails that test is stored.
--
--  Prerequisites: 052. Idempotent.
-- ===========================================================================

alter table public.madrasah_staff add column if not exists address       text;
alter table public.madrasah_staff add column if not exists date_of_birth date;
alter table public.madrasah_staff add column if not exists phone_alt     text;
--  Day -> "17:00-19:30". A jsonb object rather than seven columns: some staff
--  work four days and some six, and mon_start/mon_end x7 is fourteen columns
--  that are null most of the time.
alter table public.madrasah_staff add column if not exists work_times    jsonb;

comment on column public.madrasah_staff.date_of_birth is
  'Held because a DBS check is against a person and a date of birth is how the '
  'certificate is matched to them. Not shown on the staff list - only on the '
  'person''s own record.';
comment on column public.madrasah_staff.work_times is
  'Which hours on which days, as {"mon":"17:00-19:30", ...}. Absent days are '
  'days they are not in.';
comment on column public.madrasah_staff.phone_alt is
  'A second number where the masjid holds one - usually a landline beside a '
  'mobile. 4 of 40.';

-- ---------------------------------------------------------------------------
--  ONE PERSON'S RECORD, IN FULL.
--
--  Its own function rather than widening madrasah_staff_list(), because the
--  LIST does not need an address and a date of birth on forty rows - it needs
--  to know whether there IS one, which is what the icons on each row say.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_staff_one(p_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid(); v_row public.madrasah_staff%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open a staff record.'
      using errcode = '42501';
  end if;
  select * into v_row from public.madrasah_staff
   where id = p_id and masjid_id = v_masjid;
  if v_row.id is null then
    raise exception 'There is no such member of staff at this masjid.' using errcode = 'no_data_found';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'name', btrim(concat_ws(' ', v_row.honorific, v_row.first_name, v_row.last_name)),
    'honorific', v_row.honorific, 'first_name', v_row.first_name, 'last_name', v_row.last_name,
    'side', v_row.side, 'employment', v_row.employment,
    'started_on', v_row.started_on, 'left_on', v_row.left_on,
    'address', v_row.address, 'date_of_birth', v_row.date_of_birth,
    'email', v_row.email, 'phone', v_row.phone, 'phone_alt', v_row.phone_alt,
    'note', v_row.note,
    'work_days', v_row.work_days, 'work_times', v_row.work_times,
    'dbs_issued', v_row.dbs_issued, 'dbs_update_service', v_row.dbs_update_service,
    'dbs_last_checked', v_row.dbs_last_checked, 'dbs_not_required', v_row.dbs_not_required,
    'prior_dbs', v_row.prior_dbs,
    'dbs', public.dbs_state(v_row.dbs_issued, v_row.dbs_update_service,
                            v_row.dbs_last_checked, v_row.dbs_not_required),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name)
             order by c.sort_order, c.name)
        from public.madrasah_staff_classes sc
        join public.madrasah_classes c on c.id = sc.class_id
       where sc.staff_id = v_row.id and sc.masjid_id = v_masjid), '[]'::jsonb),
    'main_teacher_of', coalesce((
      select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name)
        from public.madrasah_classes c
       where c.main_teacher_id = v_row.id and c.masjid_id = v_masjid), '[]'::jsonb));
end $fn$;

revoke all on function public.madrasah_staff_one(uuid) from public, anon;
grant execute on function public.madrasah_staff_one(uuid) to authenticated;

do $check$
declare v_cols text;
begin
  --  THE FOUR THAT MUST NOT APPEAR. If one ever does, somebody added it
  --  without the argument at the top of this file being revisited.
  select string_agg(column_name, ', ' order by column_name) into v_cols
    from information_schema.columns
   where table_schema = 'public' and table_name = 'madrasah_staff'
     and column_name in ('dbs_number','dbs_certificate','certificate_number',
                         'ni_number','national_insurance','nino',
                         'bank_account','account_number','sort_code','gender');
  if v_cols is not null then
    raise exception 'madrasah_staff has grown fields the masjid decided against: %', v_cols;
  end if;
end $check$;
