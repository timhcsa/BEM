-- =====================================================================
-- BEM Ledger — taxable vs. non-taxable payments to missionaries.
-- Every line of a payment to a missionary carries a tax treatment:
--   taxable        salary, extra funds for personal use      -> 1099-NEC box 1
--   reimbursement  business expenses repaid under BEM's accountable
--                  plan (receipts on file)                   -> not reported
--   housing        board-designated minister's housing allowance
--                  -> not in box 1; shown separately for reference
-- Payments to other payees keep using the account's 1099 setting.
-- Safe to re-run.
-- =====================================================================

alter table disbursement_lines add column if not exists tax_treatment text
  check (tax_treatment in ('taxable','reimbursement','housing'));
alter table recurring_payment_lines add column if not exists tax_treatment text
  check (tax_treatment in ('taxable','reimbursement','housing'));

-- A category for extra funds a missionary requests for salary or personal use.
insert into accounts (id, code, name, type, subtype, functional_class, is_system, sort, description, tax_form)
values ('a0000000-0000-0000-0000-000000005030', '5030', 'Missionary Support - Additional Funds', 'expense', 'expense', 'program',
        false, 503, 'Extra funds a missionary requests for salary or personal use (taxable).', 'nec1')
on conflict (id) do nothing;

-- Default treatment for an expense account when paying a missionary.
create or replace function _default_tax_treatment(p_account uuid) returns text
language sql stable as $$
  select case when a.code = '5010' then 'housing'
              when a.tax_form = 'nec1' then 'taxable'
              else 'reimbursement' end
    from accounts a where a.id = p_account
$$;

-- Backfill earlier missionary payments that have no treatment yet.
update disbursement_lines dl set tax_treatment = _default_tax_treatment(dl.account_id)
  from disbursements d
 where d.id = dl.disbursement_id and d.missionary_id is not null and dl.tax_treatment is null;
update recurring_payment_lines l set tax_treatment = _default_tax_treatment(l.account_id)
  from recurring_payments r
 where r.id = l.recurring_id and r.missionary_id is not null and l.tax_treatment is null;

-- Form 1099 report, now honoring each line's tax treatment.
create or replace function report_1099(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr),
  lines as (
    select d.payee_id, d.id disb_id, d.disb_number, d.disb_date, d.method, a.code, a.name account_name, a.tax_form,
           dl.tax_treatment, dl.amount, dl.memo,
           case when d.method = 'debit_card' then false
                when dl.tax_treatment = 'taxable' then true
                when dl.tax_treatment in ('reimbursement','housing') then false
                else a.tax_form = 'nec1' end as is_nec,
           (dl.tax_treatment = 'housing' or (dl.tax_treatment is null and a.code = '5010')) as is_housing,
           (dl.tax_treatment = 'reimbursement' or (dl.tax_treatment is null and a.code in ('5100','5150'))) as is_reimb
      from disbursements d join disbursement_lines dl on dl.disbursement_id = d.id join accounts a on a.id = dl.account_id, y
     where d.status = 'posted' and extract(year from d.disb_date) = y.yr and d.payee_id is not null),
  per as (
    select payee_id,
      coalesce(sum(amount) filter (where is_nec), 0) nec1,
      coalesce(sum(amount) filter (where tax_treatment is null and tax_form = 'misc1' and method <> 'debit_card'), 0) misc1,
      coalesce(sum(amount) filter (where tax_treatment is null and tax_form = 'misc3' and method <> 'debit_card'), 0) misc3,
      coalesce(sum(amount) filter (where is_housing), 0) housing,
      coalesce(sum(amount) filter (where is_reimb), 0) reimbursed,
      coalesce(sum(amount) filter (where method = 'debit_card' and (tax_treatment = 'taxable' or (tax_treatment is null and tax_form is not null))), 0) card_paid,
      coalesce(sum(amount), 0) total_paid,
      jsonb_agg(jsonb_build_object('disbursement_id', disb_id, 'disb_number', disb_number, 'date', disb_date, 'method', method,
                  'account', code || ' · ' || account_name, 'treatment', tax_treatment, 'memo', memo, 'amount', amount,
                  'counted', case when is_nec then 'nec1'
                                  when tax_treatment is null and tax_form in ('misc1','misc3') and method <> 'debit_card' then tax_form
                                  when is_housing then 'housing' when is_reimb then 'reimbursement'
                                  when method = 'debit_card' then 'card' else 'not reported' end)
                order by disb_date, disb_number) detail
      from lines group by payee_id)
  select jsonb_build_object(
    'year', (select yr from y),
    'threshold', _1099_threshold((select yr from y)),
    'payer', (select jsonb_build_object('name', org_name, 'ein', ein, 'address', address, 'phone', phone) from settings where id = 1),
    'recipients', coalesce((select jsonb_agg(jsonb_build_object(
        'payee_id', py.id, 'display_name', py.display_name, 'legal_name', coalesce(py.legal_name, py.display_name),
        'business_name', py.business_name, 'tin_type', py.tin_type, 'tin', _fmt_tin(py.tin_type, py.tin),
        'tin_masked', _mask_tin(py.tin_type, py.tin),
        'address_line1', py.address_line1, 'address_line2', py.address_line2, 'city', py.city, 'state', py.state,
        'postal_code', py.postal_code, 'email', py.email, 'is_1099', py.is_1099, 'w9_on_file', py.w9_on_file,
        'missionary', py.missionary_id is not null,
        'nec1', per.nec1, 'misc1', per.misc1, 'misc3', per.misc3, 'housing', per.housing, 'reimbursed', per.reimbursed,
        'card_paid', per.card_paid, 'total_paid', per.total_paid, 'detail', per.detail,
        'needs_nec', per.nec1 >= _1099_threshold((select yr from y)),
        'needs_misc', per.misc1 >= 600 or per.misc3 >= 600,
        'problems', array_remove(array[
            case when py.tin is null then 'No taxpayer ID (get a Form W-9)' end,
            case when py.tin_type is null and py.tin is not null then 'SSN or EIN not specified' end,
            case when py.address_line1 is null or py.city is null or py.state is null or py.postal_code is null then 'Incomplete address' end,
            case when py.legal_name is null then 'Legal name not entered (using the payee name)' end,
            case when not py.is_1099 then 'Payee is not marked to receive a 1099' end], null))
        order by (per.nec1 + per.misc1 + per.misc3) desc, py.display_name)
      from per join payees py on py.id = per.payee_id
     where py.is_1099 or per.nec1 + per.misc1 + per.misc3 > 0 or py.missionary_id is not null), '[]'))
$$;
