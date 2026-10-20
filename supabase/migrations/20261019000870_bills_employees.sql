-- =====================================================================
-- BEM Ledger — bills & expense reports, missionaries as employees,
-- reimbursement categories, $200 monthly admin-fee cap. Safe to re-run.
--
-- Bills (accrual, GAAP): entering a bill or a missionary's expense report
-- records the expense and an Accounts Payable liability in the fund:
--     Dr expense (fund)            Cr 2000 Accounts Payable (fund)
-- Paying it later (check # or EFT) clears the liability from the bank:
--     Dr 2000 Accounts Payable     Cr 1000 Checking
-- A missionary fund can only pay what it has in cash: an expense report
-- waits, unpaid, until enough donations have come in.
-- =====================================================================

-- One-time changes are recorded here so re-running never repeats them.
create table if not exists schema_marks (name text primary key, applied_at timestamptz not null default now());

-- ---------------------------------------------------------------------
-- Settings: $200 monthly cap (BEM policy), IRS mileage rate
-- ---------------------------------------------------------------------
alter table settings add column if not exists mileage_rate numeric(6,4) not null default 0.7600;  -- IRS business rate from 7/1/2026
do $$ begin
  if not exists (select 1 from schema_marks where name = 'admin_fee_cap_200') then
    update settings set default_admin_fee_cap = 200.00 where id = 1 and default_admin_fee_cap = 250.00;
    insert into schema_marks(name) values ('admin_fee_cap_200');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Missionaries are employees (W-2). One-time switch of existing payees.
-- ---------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from schema_marks where name = 'missionaries_are_employees') then
    update payees set worker_type = 'employee', is_1099 = false where missionary_id is not null;
    update payees set worker_type = 'contractor' where missionary_id is null and is_1099;
    insert into schema_marks(name) values ('missionaries_are_employees');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Chart of accounts: payables, reimbursement categories, BEM business
-- ---------------------------------------------------------------------
alter table accounts add column if not exists reimbursable boolean not null default false;  -- offered on expense reports
alter table accounts add column if not exists per_mile boolean not null default false;      -- amount = miles x mileage rate
alter table accounts drop constraint if exists accounts_subtype_check;
alter table accounts add constraint accounts_subtype_check check (subtype in
  ('bank','undeposited','payable','interfund_fee','interfund_transfer','opening_without','opening_with',
   'contribution_individual','contribution_organization','program_revenue','other_revenue','expense','other'));

insert into accounts (id, code, name, type, subtype, functional_class, is_system, sort, description, reimbursable, per_mile) values
 ('a0000000-0000-0000-0000-000000002000','2000','Accounts Payable','liability','payable',null,true,200,'Bills and expense reports entered but not yet paid.',false,false),
 ('a0000000-0000-0000-0000-000000005040','5040','Medical Expense Reimbursement','expense','expense','program',false,504,'Employee medical expenses reimbursed. Non-taxable only under a qualified plan (QSEHRA/ICHRA); confirm with your CPA.',true,false),
 ('a0000000-0000-0000-0000-000000005110','5110','Business Meals','expense','expense','program',false,511,'Missionary business meals (receipts on file).',true,false),
 ('a0000000-0000-0000-0000-000000005120','5120','Mileage','expense','expense','program',false,512,'Ministry miles driven in a personal vehicle, at the IRS rate.',true,true),
 ('a0000000-0000-0000-0000-000000005130','5130','Lodging','expense','expense','program',false,513,null,true,false),
 ('a0000000-0000-0000-0000-000000005140','5140','Ministry Office Supplies','expense','expense','program',false,514,null,true,false),
 ('a0000000-0000-0000-0000-000000005160','5160','Phone & Internet','expense','expense','program',false,516,null,true,false),
 ('a0000000-0000-0000-0000-000000005170','5170','Ministry Materials & Books','expense','expense','program',false,517,null,true,false),
 ('a0000000-0000-0000-0000-000000005180','5180','Conference & Registration Fees','expense','expense','program',false,518,null,true,false),
 ('a0000000-0000-0000-0000-000000006045','6045','Office Supplies','expense','expense','management_general',false,604,'BEM office supplies (General Fund).',false,false),
 ('a0000000-0000-0000-0000-000000006060','6060','Mileage - BEM Business','expense','expense','management_general',false,606,'Miles driven on BEM business, at the IRS rate.',true,true),
 ('a0000000-0000-0000-0000-000000006065','6065','Travel - BEM Business','expense','expense','management_general',false,607,null,true,false)
on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from schema_marks where name = 'reimbursable_accounts') then
    update accounts set reimbursable = true where code in ('5100','5150');
    insert into schema_marks(name) values ('reimbursable_accounts');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Ledger: new entry types
-- ---------------------------------------------------------------------
alter table journal_entries drop constraint if exists journal_entries_source_type_check;
alter table journal_entries add constraint journal_entries_source_type_check check (source_type in
  ('gift','admin_fee','deposit','disbursement','transfer','opening','adjustment','reversal','bill','bill_payment'));

-- ---------------------------------------------------------------------
-- Bills & expense reports
-- ---------------------------------------------------------------------
-- (bill tables and _fund_cash/_fund_unpaid live in 20261019000150_bills_tables.sql)

-- p: {kind, payee_name, payee_id?, missionary_id?, bill_date, due_date, reference, memo,
--     lines:[{fund_id, account_id, functional_class, tax_treatment, amount, quantity, rate, expense_date, memo}]}
create or replace function post_bill(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid; v_date date; v_total numeric := 0; l jsonb; v_acct accounts; v_amt numeric; v_ap uuid := _acct('payable');
        v_lines jsonb := '[]'; v_fc text; v_tt text; v_entry uuid; i int := 0; v_missionary uuid := nullif(p->>'missionary_id','')::uuid;
        v_kind text := coalesce(nullif(p->>'kind',''), case when nullif(p->>'missionary_id','') is not null then 'expense_report' else 'bill' end);
begin
  v_date := _date(p->>'bill_date', 'Date');
  if nullif(trim(p->>'payee_name'),'') is null and v_missionary is null then raise exception 'Who is this bill from?'; end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line'; end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_amt := _money(l->>'amount', 'Amount');
    if v_amt <= 0 then raise exception 'Each line needs an amount above $0.00'; end if;
    select * into v_acct from accounts where id = nullif(l->>'account_id','')::uuid;
    if v_acct.id is null or v_acct.type <> 'expense' then raise exception 'Choose an expense category for each line'; end if;
    if not exists (select 1 from funds where id = nullif(l->>'fund_id','')::uuid) then raise exception 'Choose a fund for each line'; end if;
    v_total := v_total + v_amt;
  end loop;

  insert into bills(kind, payee_id, payee_name, missionary_id, bill_date, due_date, reference, memo, total)
  values (v_kind, _resolve_payee(p),
          coalesce(nullif(trim(p->>'payee_name'),''), (select display_name from missionaries where id = v_missionary)),
          v_missionary, v_date, nullif(p->>'due_date','')::date, nullif(trim(p->>'reference'),''), nullif(trim(p->>'memo'),''), v_total)
  returning id into v_id;

  for l in select * from jsonb_array_elements(p->'lines') loop
    i := i + 1;
    select * into v_acct from accounts where id = (l->>'account_id')::uuid;
    v_fc := coalesce(nullif(l->>'functional_class',''), v_acct.functional_class, 'program');
    v_tt := case when nullif(l->>'tax_treatment','') is not null then l->>'tax_treatment'
                 when v_missionary is not null then _default_tax_treatment(v_acct.id) end;
    insert into bill_lines(bill_id, fund_id, account_id, functional_class, tax_treatment, amount, quantity, rate, expense_date, memo, sort)
    values (v_id, (l->>'fund_id')::uuid, v_acct.id, v_fc, v_tt, _money(l->>'amount','Amount'),
            nullif(l->>'quantity','')::numeric, nullif(l->>'rate','')::numeric, nullif(l->>'expense_date','')::date,
            nullif(trim(l->>'memo'),''), i);
    v_lines := v_lines
      || jsonb_build_object('account_id', v_acct.id, 'fund_id', l->>'fund_id', 'debit', _money(l->>'amount','Amount'),
                            'functional_class', v_fc, 'memo', nullif(trim(l->>'memo'),''))
      || jsonb_build_object('account_id', v_ap, 'fund_id', l->>'fund_id', 'credit', _money(l->>'amount','Amount'));
  end loop;
  v_entry := _post_entry(v_date, case v_kind when 'expense_report' then 'Expense report' else 'Bill' end || ' from '
                         || (select payee_name from bills where id = v_id), 'bill', v_id, v_lines);
  update bills set journal_entry_id = v_entry where id = v_id;
  return get_bill(jsonb_build_object('id', v_id));
end $$;

create or replace function get_bill(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(b) || jsonb_build_object(
    'payment', (select to_jsonb(bp) from bill_payments bp where bp.id = b.payment_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(bl) || jsonb_build_object('fund_name', f.name, 'fund_kind', f.kind,
                 'account_name', a.code || ' · ' || a.name) order by bl.sort), '[]')
                from bill_lines bl join funds f on f.id = bl.fund_id join accounts a on a.id = bl.account_id where bl.bill_id = b.id))
  from bills b where b.id = (p->>'id')::uuid
$$;

-- p: {status: 'open'|'paid'|'void'|'', missionary_id, fund_id, from, to}
create or replace function list_bills(p jsonb) returns jsonb
language sql stable as $$
  with fund_need as (   -- for open bills: can each fund cover its share right now?
    select bl.bill_id, bool_and(_fund_cash(bl.fund_id) >= bl.amount) covered,
           string_agg(distinct f.name || ' has ' || to_char(_fund_cash(bl.fund_id), 'FM$999,999,990.00'), '; ')
             filter (where _fund_cash(bl.fund_id) < bl.amount) short
      from bill_lines bl join bills b on b.id = bl.bill_id join funds f on f.id = bl.fund_id
     where b.status = 'open' group by bl.bill_id)
  select coalesce(jsonb_agg(to_jsonb(b) || jsonb_build_object(
      'funds', (select string_agg(distinct f.name, ', ') from bill_lines bl join funds f on f.id = bl.fund_id where bl.bill_id = b.id),
      'categories', (select string_agg(distinct a.name, ', ') from bill_lines bl join accounts a on a.id = bl.account_id where bl.bill_id = b.id),
      'missionary_fund', (select bool_or(f.kind = 'missionary') from bill_lines bl join funds f on f.id = bl.fund_id where bl.bill_id = b.id),
      'can_pay', coalesce(fn.covered, false), 'short', fn.short,
      'payment_number', (select payment_number from bill_payments where id = b.payment_id),
      'paid_date', (select pay_date from bill_payments where id = b.payment_id),
      'paid_reference', (select reference from bill_payments where id = b.payment_id),
      'paid_method', (select method from bill_payments where id = b.payment_id))
      order by b.status = 'open' desc, coalesce(b.due_date, b.bill_date), b.bill_number), '[]')
    from bills b left join fund_need fn on fn.bill_id = b.id
   where (nullif(p->>'status','') is null or b.status = p->>'status')
     and (nullif(p->>'missionary_id','') is null or b.missionary_id = (p->>'missionary_id')::uuid)
     and (nullif(p->>'fund_id','') is null or exists (select 1 from bill_lines where bill_id = b.id and fund_id = (p->>'fund_id')::uuid))
     and (nullif(p->>'from','') is null or b.bill_date >= (p->>'from')::date)
     and (nullif(p->>'to','') is null or b.bill_date <= (p->>'to')::date)
$$;

create or replace function void_bill(p jsonb) returns jsonb
language plpgsql as $$
declare v_b bills; v_reason text := nullif(trim(p->>'reason'),'');
begin
  select * into v_b from bills where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Bill not found'; end if;
  if v_b.status = 'paid' then raise exception 'This bill has been paid. Void the payment first.'; end if;
  if v_b.status = 'void' then raise exception 'Already void'; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  perform _reverse_entry(v_b.journal_entry_id, 'VOID bill #' || v_b.bill_number || ': ' || v_reason);
  update bills set status = 'void', void_reason = v_reason, voided_at = now() where id = v_b.id;
  return get_bill(p);
end $$;

-- Pay one payee's bills with one check or EFT.
-- p: {pay_date, method, reference, memo, bank_account_id?, bill_ids:[...], allow_overdraft}
-- Missionary funds can never be overdrawn; other funds need allow_overdraft.
create or replace function pay_bills(p jsonb) returns jsonb
language plpgsql as $$
declare v_ids uuid[]; v_date date; v_bank uuid; v_ap uuid := _acct('payable'); v_pay uuid; v_total numeric; v_payees int;
        r record; v_short text := ''; v_strict text := ''; v_lines jsonb; v_entry uuid; v_first bills;
begin
  v_date := _date(p->>'pay_date', 'Payment date');
  v_bank := _bank_account(p);
  if coalesce(p->>'method','') not in ('check','ach','debit_card','wire','other') then raise exception 'Choose check or EFT'; end if;
  if p->>'method' = 'check' and nullif(trim(p->>'reference'),'') is null then raise exception 'Enter the check number'; end if;
  select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(p->'bill_ids') x;
  if v_ids is null then raise exception 'Select the bills to pay'; end if;
  if (select count(*) from bills where id = any(v_ids) and status = 'open') <> array_length(v_ids, 1) then
    raise exception 'Some selected bills are already paid or void. Refresh and try again.';
  end if;
  select count(distinct coalesce(payee_id::text, lower(payee_name))) into v_payees from bills where id = any(v_ids);
  if v_payees > 1 then raise exception 'Pay one payee at a time (one check or EFT per payee)'; end if;
  if exists (select 1 from bills where id = any(v_ids) and bill_date > v_date) then
    raise exception 'A bill cannot be paid before its date';
  end if;

  for r in select bl.fund_id, f.name, f.kind, sum(bl.amount) amt from bill_lines bl join funds f on f.id = bl.fund_id
            where bl.bill_id = any(v_ids) group by bl.fund_id, f.name, f.kind loop
    if _fund_cash(r.fund_id) < r.amt then
      if r.kind = 'missionary' then
        v_strict := v_strict || r.name || ' has ' || _fmt(_fund_cash(r.fund_id)) || ' but needs ' || _fmt(r.amt) || '; ';
      else
        v_short := v_short || r.name || ' has ' || _fmt(_fund_cash(r.fund_id)) || ' but needs ' || _fmt(r.amt) || '; ';
      end if;
    end if;
  end loop;
  if v_strict <> '' then
    raise exception 'Not enough in the missionary account yet: %. It can be paid once more donations come in.', rtrim(v_strict, '; ');
  end if;
  if v_short <> '' and not coalesce((p->>'allow_overdraft')::boolean, false) then
    raise exception 'OVERDRAFT: %', rtrim(v_short, '; ');
  end if;

  select sum(total) into v_total from bills where id = any(v_ids);
  select * into v_first from bills where id = v_ids[1];
  insert into bill_payments(pay_date, payee_id, payee_name, method, reference, bank_account_id, total, memo)
  values (v_date, v_first.payee_id, v_first.payee_name, p->>'method', nullif(trim(p->>'reference'),''), v_bank, v_total, nullif(trim(p->>'memo'),''))
  returning id into v_pay;

  select jsonb_agg(x) into v_lines from (
    select jsonb_build_object('account_id', v_ap, 'fund_id', bl.fund_id, 'debit', sum(bl.amount)) x
      from bill_lines bl where bl.bill_id = any(v_ids) group by bl.fund_id
    union all
    select jsonb_build_object('account_id', v_bank, 'fund_id', bl.fund_id, 'credit', sum(bl.amount))
      from bill_lines bl where bl.bill_id = any(v_ids) group by bl.fund_id) s;
  v_entry := _post_entry(v_date, 'Bill payment to ' || v_first.payee_name, 'bill_payment', v_pay, v_lines);
  update bill_payments set journal_entry_id = v_entry where id = v_pay;
  update bills set status = 'paid', payment_id = v_pay where id = any(v_ids);
  return (select to_jsonb(bp) from bill_payments bp where id = v_pay);
end $$;

create or replace function void_bill_payment(p jsonb) returns jsonb
language plpgsql as $$
declare v_p bill_payments; v_reason text := nullif(trim(p->>'reason'),'');
begin
  select * into v_p from bill_payments where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_p.status = 'void' then raise exception 'Already void'; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  if _is_cleared(v_p.journal_entry_id) then raise exception 'This payment has cleared the bank on a completed reconciliation and cannot be voided'; end if;
  perform _reverse_entry(v_p.journal_entry_id, 'VOID bill payment #' || v_p.payment_number || ': ' || v_reason);
  update bill_payments set status = 'void', void_reason = v_reason, voided_at = now() where id = v_p.id;
  update bills set status = 'open', payment_id = null where payment_id = v_p.id;   -- the bills are owed again
  return (select to_jsonb(bp) from bill_payments bp where id = v_p.id);
end $$;

create or replace function list_bill_payments(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(bp) || jsonb_build_object('cleared', _is_cleared(bp.journal_entry_id),
           'bills', (select string_agg('#' || bill_number, ', ' order by bill_number) from bills where payment_id = bp.id))
           order by bp.pay_date desc, bp.payment_number desc), '[]')
    from (select * from bill_payments order by pay_date desc, payment_number desc limit coalesce(nullif(p->>'limit','')::int, 200)) bp
$$;

-- ---------------------------------------------------------------------
-- Everything paid to a payee in a year: direct payments plus bills paid
-- (cash basis, dated when paid). Used by the 1099 and W-2 reports.
-- ---------------------------------------------------------------------
create or replace function _paid_lines(p_year int)
returns table(payee_id uuid, doc text, doc_number bigint, pay_date date, method text, code text, account_name text,
              tax_form text, tax_treatment text, amount numeric, memo text)
language sql stable as $$
  select d.payee_id, 'payment', d.disb_number, d.disb_date, d.method, a.code, a.name, a.tax_form, dl.tax_treatment, dl.amount, dl.memo
    from disbursements d join disbursement_lines dl on dl.disbursement_id = d.id join accounts a on a.id = dl.account_id
   where d.status = 'posted' and extract(year from d.disb_date) = p_year and d.payee_id is not null
  union all
  select b.payee_id, 'bill', b.bill_number, bp.pay_date, bp.method, a.code, a.name, a.tax_form, bl.tax_treatment, bl.amount, bl.memo
    from bills b join bill_payments bp on bp.id = b.payment_id and bp.status = 'posted'
    join bill_lines bl on bl.bill_id = b.id join accounts a on a.id = bl.account_id
   where b.status = 'paid' and extract(year from bp.pay_date) = p_year and b.payee_id is not null
$$;

-- Form 1099 (contractors only; employees get a W-2).
create or replace function report_1099(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr),
  lines as (
    select l.*,
           case when l.method = 'debit_card' then false
                when l.tax_treatment = 'taxable' then true
                when l.tax_treatment in ('reimbursement','housing') then false
                else l.tax_form = 'nec1' end as is_nec,
           (l.tax_treatment = 'housing' or (l.tax_treatment is null and l.code = '5010')) as is_housing,
           (l.tax_treatment = 'reimbursement' or (l.tax_treatment is null and l.code in ('5100','5150'))) as is_reimb
      from y, _paid_lines(y.yr) l),
  per as (
    select payee_id,
      coalesce(sum(amount) filter (where is_nec), 0) nec1,
      coalesce(sum(amount) filter (where tax_treatment is null and tax_form = 'misc1' and method <> 'debit_card'), 0) misc1,
      coalesce(sum(amount) filter (where tax_treatment is null and tax_form = 'misc3' and method <> 'debit_card'), 0) misc3,
      coalesce(sum(amount) filter (where is_housing), 0) housing,
      coalesce(sum(amount) filter (where is_reimb), 0) reimbursed,
      coalesce(sum(amount) filter (where method = 'debit_card' and (tax_treatment = 'taxable' or (tax_treatment is null and tax_form is not null))), 0) card_paid,
      coalesce(sum(amount), 0) total_paid,
      jsonb_agg(jsonb_build_object('doc', doc, 'disb_number', doc_number, 'date', pay_date, 'method', method,
                  'account', code || ' · ' || account_name, 'treatment', tax_treatment, 'memo', memo, 'amount', amount,
                  'counted', case when is_nec then 'nec1'
                                  when tax_treatment is null and tax_form in ('misc1','misc3') and method <> 'debit_card' then tax_form
                                  when is_housing then 'housing' when is_reimb then 'reimbursement'
                                  when method = 'debit_card' then 'card' else 'not reported' end)
                order by pay_date, doc_number) detail
      from lines group by payee_id)
  select jsonb_build_object(
    'year', (select yr from y),
    'threshold', _1099_threshold((select yr from y)),
    'payer', (select jsonb_build_object('name', org_name, 'ein', ein, 'address', address, 'phone', phone) from settings where id = 1),
    'employees_excluded', (select count(*) from per join payees py on py.id = per.payee_id where py.worker_type = 'employee'),
    'recipients', coalesce((select jsonb_agg(jsonb_build_object(
        'payee_id', py.id, 'display_name', py.display_name, 'legal_name', coalesce(py.legal_name, py.display_name),
        'business_name', py.business_name, 'tin_type', py.tin_type, 'tin', _fmt_tin(py.tin_type, py.tin),
        'tin_masked', _mask_tin(py.tin_type, py.tin),
        'address_line1', py.address_line1, 'address_line2', py.address_line2, 'city', py.city, 'state', py.state,
        'postal_code', py.postal_code, 'email', py.email, 'is_1099', py.is_1099, 'w9_on_file', py.w9_on_file,
        'missionary', py.missionary_id is not null, 'worker_type', py.worker_type,
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
     where py.worker_type <> 'employee' and (py.is_1099 or per.nec1 + per.misc1 + per.misc3 > 0)), '[]'))
$$;

-- W-2 worksheet for employees (missionaries). Figures to hand to the payroll
-- provider or CPA who files the actual W-2s.
create or replace function report_w2(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr),
  lines as (select l.* from y, _paid_lines(y.yr) l),
  per as (
    select payee_id,
      coalesce(sum(amount) filter (where tax_treatment = 'taxable' or (tax_treatment is null and tax_form = 'nec1')), 0) wages,
      coalesce(sum(amount) filter (where tax_treatment = 'housing' or (tax_treatment is null and code = '5010')), 0) housing,
      coalesce(sum(amount) filter (where code = '5040' and coalesce(tax_treatment,'reimbursement') <> 'taxable'), 0) medical,
      coalesce(sum(amount) filter (where code <> '5040' and (tax_treatment = 'reimbursement'
                                    or (tax_treatment is null and tax_form is null and code <> '5010'))), 0) reimbursed,
      coalesce(sum(amount), 0) total_paid,
      jsonb_agg(jsonb_build_object('doc', doc, 'number', doc_number, 'date', pay_date, 'account', code || ' · ' || account_name,
                  'treatment', tax_treatment, 'amount', amount, 'memo', memo) order by pay_date, doc_number) detail
      from lines group by payee_id)
  select jsonb_build_object('year', (select yr from y),
    'employer', (select jsonb_build_object('name', org_name, 'ein', ein, 'address', address) from settings where id = 1),
    'employees', coalesce((select jsonb_agg(jsonb_build_object(
        'payee_id', py.id, 'name', coalesce(py.legal_name, py.display_name), 'display_name', py.display_name,
        'tin_masked', _mask_tin(py.tin_type, py.tin), 'has_ssn', py.tin is not null,
        'address', concat_ws(', ', py.address_line1, py.city, py.state || ' ' || py.postal_code),
        'wages', per.wages, 'housing', per.housing, 'medical', per.medical, 'reimbursed', per.reimbursed,
        'total_paid', per.total_paid, 'detail', per.detail) order by py.display_name)
      from per join payees py on py.id = per.payee_id where py.worker_type = 'employee'), '[]'))
$$;
