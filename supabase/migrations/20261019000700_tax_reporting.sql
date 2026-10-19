-- =====================================================================
-- BEM Ledger — year-end tax reporting: payees and Forms 1099.
-- Safe to re-run.
--
-- * Every payment is linked to a payee. Missionaries get a payee record
--   automatically. A payee marked "receives a 1099" needs a legal name,
--   TIN and address (from their Form W-9).
-- * Each expense account says which 1099 box (if any) it feeds:
--     nec1  = 1099-NEC box 1, nonemployee compensation (e.g. missionary support)
--     misc1 = 1099-MISC box 1, rents
--     misc3 = 1099-MISC box 3, other income
--   Reimbursements under an accountable plan and the minister's housing
--   allowance are NOT reported in box 1 by default. Confirm with your CPA.
-- * Payments made by debit/credit card are excluded; the card processor
--   reports those on Form 1099-K.
-- * Threshold: $600 for payments in 2025 and earlier; $2,000 for 2026
--   (One Big Beautiful Bill Act), indexed for inflation from 2027. The
--   2027+ figure is a setting so it can be updated when the IRS announces it.
-- =====================================================================

create table if not exists payees (
  id             uuid primary key default gen_random_uuid(),
  display_name   text not null,                  -- as typed on payments
  legal_name     text,                           -- name on the W-9 / 1099
  business_name  text,                           -- "doing business as", optional
  tin_type       text check (tin_type in ('ssn','ein')),
  tin            text,                           -- digits only
  address_line1  text,
  address_line2  text,
  city           text,
  state          text,
  postal_code    text,
  email          text,
  is_1099        boolean not null default false,
  w9_on_file     boolean not null default false,
  missionary_id  uuid unique references missionaries(id),
  notes          text,
  active         boolean not null default true,
  created_at     timestamptz not null default now()
);
create unique index if not exists payees_display_name_uq on payees (lower(display_name));

alter table disbursements add column if not exists payee_id uuid references payees(id);
alter table accounts add column if not exists tax_form text check (tax_form in ('nec1','misc1','misc3'));
alter table settings add column if not exists form1099_threshold numeric(12,2) not null default 2000.00;

-- Missionary support is 1099-NEC box 1 unless set otherwise.
update accounts set tax_form = 'nec1'
 where code = '5000' and tax_form is null
   and not exists (select 1 from audit_log where object = 'account' and object_id = accounts.id);

-- ---------------------------------------------------------------------
-- Payee helpers
-- ---------------------------------------------------------------------
create or replace function _missionary_payee(p_missionary uuid) returns uuid
language plpgsql as $$
declare v uuid; v_name text;
begin
  select id into v from payees where missionary_id = p_missionary;
  if v is not null then return v; end if;
  select display_name into v_name from missionaries where id = p_missionary;
  if v_name is null then return null; end if;
  -- reuse a payee with the same name if one exists
  select id into v from payees where lower(display_name) = lower(v_name) and missionary_id is null;
  if v is not null then
    update payees set missionary_id = p_missionary, is_1099 = true where id = v;
    return v;
  end if;
  insert into payees(display_name, missionary_id, is_1099) values (v_name, p_missionary, true) returning id into v;
  return v;
end $$;

-- Find or create the payee for a payment. p: {payee_id?, missionary_id?, payee_name}
create or replace function _resolve_payee(p jsonb) returns uuid
language plpgsql as $$
declare v uuid; v_name text := nullif(trim(p->>'payee_name'),'');
begin
  v := nullif(p->>'payee_id','')::uuid;
  if v is not null and exists (select 1 from payees where id = v) then return v; end if;
  if nullif(p->>'missionary_id','') is not null then
    return _missionary_payee((p->>'missionary_id')::uuid);
  end if;
  if v_name is null then return null; end if;
  select id into v from payees where lower(display_name) = lower(v_name);
  if v is null then
    insert into payees(display_name) values (v_name) returning id into v;
  end if;
  return v;
end $$;

-- Backfill: a payee for every missionary, and link existing payments.
do $$
declare r record;
begin
  for r in select id from missionaries loop perform _missionary_payee(r.id); end loop;
  for r in select id, payee_name, missionary_id from disbursements where payee_id is null loop
    update disbursements set payee_id = _resolve_payee(jsonb_build_object('payee_name', r.payee_name, 'missionary_id', r.missionary_id))
     where id = r.id;
  end loop;
end $$;

create or replace function _mask_tin(p_type text, p_tin text) returns text
language sql immutable as $$
  select case when p_tin is null or length(p_tin) < 4 then null
              when p_type = 'ein' then 'XX-XXX' || right(p_tin, 4)
              else 'XXX-XX-' || right(p_tin, 4) end
$$;

create or replace function _fmt_tin(p_type text, p_tin text) returns text
language sql immutable as $$
  select case when p_tin is null then null
              when p_type = 'ein' and length(p_tin) = 9 then left(p_tin, 2) || '-' || right(p_tin, 7)
              when length(p_tin) = 9 then left(p_tin, 3) || '-' || substr(p_tin, 4, 2) || '-' || right(p_tin, 4)
              else p_tin end
$$;

create or replace function _1099_threshold(p_year int) returns numeric
language sql stable as $$
  select case when p_year <= 2025 then 600.00
              when p_year = 2026 then 2000.00
              else (select form1099_threshold from settings where id = 1) end
$$;

-- ---------------------------------------------------------------------
-- Payee API
-- ---------------------------------------------------------------------
create or replace function list_payees(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(x order by (x->>'is_1099')::boolean desc, lower(x->>'display_name')), '[]') from (
    select (to_jsonb(py) - 'tin') || jsonb_build_object(
             'tin_masked', _mask_tin(py.tin_type, py.tin),
             'has_tin', py.tin is not null,
             'missionary_name', m.display_name,
             'ytd_paid', (select coalesce(sum(d.total),0) from disbursements d where d.payee_id = py.id and d.status = 'posted'
                           and d.disb_date >= date_trunc('year', current_date)),
             'last_paid', (select max(disb_date) from disbursements d where d.payee_id = py.id and d.status = 'posted')) x
      from payees py left join missionaries m on m.id = py.missionary_id
     where (coalesce((p->>'include_inactive')::boolean, false) or py.active)
       and (nullif(trim(p->>'q'),'') is null or py.display_name ilike '%' || trim(p->>'q') || '%'
            or coalesce(py.legal_name,'') ilike '%' || trim(p->>'q') || '%')) s
$$;

create or replace function get_payee(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(py) || jsonb_build_object('tin_formatted', _fmt_tin(py.tin_type, py.tin), 'missionary_name', m.display_name)
    from payees py left join missionaries m on m.id = py.missionary_id
   where py.id = coalesce(nullif(p->>'id','')::uuid, (select id from payees where missionary_id = nullif(p->>'missionary_id','')::uuid))
$$;

create or replace function save_payee(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_tin text;
begin
  if nullif(trim(p->>'display_name'),'') is null then raise exception 'Payee name is required'; end if;
  v_tin := nullif(regexp_replace(coalesce(p->>'tin',''), '[^0-9]', '', 'g'), '');
  if v_tin is not null and length(v_tin) <> 9 then raise exception 'A taxpayer ID number has 9 digits'; end if;
  if coalesce((p->>'is_1099')::boolean, false) and coalesce(nullif(p->>'tin_type',''),'') = '' and v_tin is not null then
    raise exception 'Say whether the taxpayer ID is an SSN or an EIN';
  end if;
  if v_id is null then
    insert into payees(display_name) values (trim(p->>'display_name')) returning id into v_id;
  end if;
  update payees set
    display_name = trim(p->>'display_name'),
    legal_name = nullif(trim(p->>'legal_name'),''), business_name = nullif(trim(p->>'business_name'),''),
    tin_type = nullif(p->>'tin_type',''),
    tin = case when p ? 'tin' then v_tin else tin end,   -- omit "tin" to keep the stored number
    address_line1 = nullif(trim(p->>'address_line1'),''), address_line2 = nullif(trim(p->>'address_line2'),''),
    city = nullif(trim(p->>'city'),''), state = nullif(upper(trim(p->>'state')),''), postal_code = nullif(trim(p->>'postal_code'),''),
    email = nullif(trim(p->>'email'),''),
    is_1099 = coalesce((p->>'is_1099')::boolean, false), w9_on_file = coalesce((p->>'w9_on_file')::boolean, false),
    notes = nullif(trim(p->>'notes'),''), active = coalesce((p->>'active')::boolean, true)
  where id = v_id;
  perform _log('save', 'payee', v_id, p - 'tin');
  return (select (to_jsonb(py) - 'tin') || jsonb_build_object('tin_masked', _mask_tin(py.tin_type, py.tin)) from payees py where id = v_id);
exception when unique_violation then
  raise exception 'Another payee already has that name';
end $$;

-- ---------------------------------------------------------------------
-- Form 1099 report. p: {year}
-- ---------------------------------------------------------------------
create or replace function report_1099(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr),
  lines as (
    select d.payee_id, a.tax_form, a.code, dl.amount, d.method
      from disbursements d join disbursement_lines dl on dl.disbursement_id = d.id join accounts a on a.id = dl.account_id, y
     where d.status = 'posted' and extract(year from d.disb_date) = y.yr and d.payee_id is not null),
  per as (
    select payee_id,
      coalesce(sum(amount) filter (where tax_form = 'nec1' and method <> 'debit_card'), 0) nec1,
      coalesce(sum(amount) filter (where tax_form = 'misc1' and method <> 'debit_card'), 0) misc1,
      coalesce(sum(amount) filter (where tax_form = 'misc3' and method <> 'debit_card'), 0) misc3,
      coalesce(sum(amount) filter (where code = '5010'), 0) housing,
      coalesce(sum(amount) filter (where code in ('5100','5150')), 0) reimbursed,
      coalesce(sum(amount) filter (where method = 'debit_card' and tax_form is not null), 0) card_paid,
      coalesce(sum(amount), 0) total_paid
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
        'card_paid', per.card_paid, 'total_paid', per.total_paid,
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
     where py.is_1099 or per.nec1 + per.misc1 + per.misc3 > 0), '[]'))
$$;

-- Accounts screen: allow setting the 1099 box (save_account is redefined here to add tax_form).
create or replace function save_account(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid;
begin
  if nullif(trim(p->>'code'),'') is null or nullif(trim(p->>'name'),'') is null then raise exception 'Account needs a number and a name'; end if;
  if v_id is null then
    if coalesce(p->>'type','') not in ('asset','liability','revenue','expense') then raise exception 'Choose an account type'; end if;
    insert into accounts(code, name, type, subtype, functional_class, description, sort, tax_form)
    values (trim(p->>'code'), trim(p->>'name'), p->>'type',
            case p->>'type' when 'expense' then 'expense' when 'revenue' then coalesce(nullif(p->>'subtype',''),'other_revenue')
                            when 'asset' then case when p->>'subtype' = 'bank' then 'bank' else 'other' end else 'other' end,
            case when p->>'type' = 'expense' then coalesce(nullif(p->>'functional_class',''),'management_general') end,
            nullif(trim(p->>'description'),''), coalesce(nullif(p->>'sort','')::int, (trim(p->>'code'))::int),
            case when p->>'type' = 'expense' then nullif(p->>'tax_form','') end)
    returning id into v_id;
  else
    update accounts set code = case when is_system then code else trim(p->>'code') end, name = trim(p->>'name'),
      functional_class = case when type = 'expense' then coalesce(nullif(p->>'functional_class',''), functional_class) end,
      tax_form = case when type = 'expense' then nullif(p->>'tax_form','') end,
      description = nullif(trim(p->>'description'),''),
      active = case when is_system then true else coalesce((p->>'active')::boolean, active) end
    where id = v_id;
  end if;
  perform _log('save', 'account', v_id, p);
  return (select to_jsonb(a) from accounts a where id = v_id);
exception when invalid_text_representation then
  raise exception 'Account number must be numeric';
end $$;

-- ---------------------------------------------------------------------
-- Donor statements v2: cash gifts totalled; non-cash gifts listed with a
-- description only (the IRS requires the charity to describe, not value,
-- non-cash property). p: {year, donor_id?, delivery: 'email'|'mail'|'all'}
-- ---------------------------------------------------------------------
create or replace function report_donor_statements(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr)
  select jsonb_build_object('year', (select yr from y), 'settings', (select to_jsonb(s) from settings s where id = 1),
    'statements', coalesce(jsonb_agg(jsonb_build_object('donor', to_jsonb(d), 'total', t.cash_total, 'noncash_count', t.noncash_count,
       'gifts', (select jsonb_agg(jsonb_build_object('gift_number', g.gift_number, 'gift_date', g.gift_date, 'method', g.method,
                    'reference', g.reference, 'amount', g.total_amount, 'memo', g.memo,
                    'designation', (select string_agg(f.name, ', ' order by f.sort) from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id))
                    order by g.gift_date, g.gift_number)
                   from gifts g, y where g.donor_id = d.id and g.status = 'posted' and g.method <> 'stock' and extract(year from g.gift_date) = y.yr),
       'noncash', (select jsonb_agg(jsonb_build_object('gift_number', g.gift_number, 'gift_date', g.gift_date,
                    'description', coalesce(g.memo, 'Non-cash gift') || coalesce(' (ref ' || g.reference || ')', ''),
                    'designation', (select string_agg(f.name, ', ' order by f.sort) from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id))
                    order by g.gift_date)
                   from gifts g, y where g.donor_id = d.id and g.status = 'posted' and g.method = 'stock' and extract(year from g.gift_date) = y.yr))
       order by d.sort_name), '[]'))
  from donors d
  join (select g.donor_id,
               coalesce(sum(g.total_amount) filter (where g.method <> 'stock'), 0) cash_total,
               count(*) filter (where g.method = 'stock') noncash_count
          from gifts g, y
         where g.status = 'posted' and extract(year from g.gift_date) = y.yr group by g.donor_id) t on t.donor_id = d.id
  where (nullif(p->>'donor_id','') is null or d.id = (p->>'donor_id')::uuid)
    and (coalesce(nullif(p->>'delivery',''), 'all') = 'all' or d.receipt_preference = p->>'delivery')
$$;

-- Missionaries created from now on get a payee automatically.
create or replace function _missionary_payee_trg() returns trigger language plpgsql as $$
begin
  perform _missionary_payee(new.id);
  update payees set display_name = new.display_name where missionary_id = new.id and display_name <> new.display_name
    and not exists (select 1 from payees x where lower(x.display_name) = lower(new.display_name) and x.missionary_id is distinct from new.id);
  return null;
end $$;
drop trigger if exists missionary_payee_trg on missionaries;
create trigger missionary_payee_trg after insert or update of display_name on missionaries
  for each row execute function _missionary_payee_trg();
