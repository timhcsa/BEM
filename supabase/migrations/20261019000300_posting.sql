-- =====================================================================
-- BEM Ledger — posting rules (the accounting engine)
--
-- Every screen in the app talks to the database through functions of
-- the form   fn(p jsonb) returns jsonb   so that the same calls work
-- locally (PGlite) and on Supabase (supabase.rpc('fn', { p })).
--
-- Bank model: all funds share the Operating Checking account. A gift is
-- first recorded in Undeposited Gifts; "Make a deposit" moves it to
-- Checking, which is what appears on the bank statement.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------
create or replace function _acct(p_subtype text) returns uuid
language sql stable as $$
  select id from accounts where subtype = p_subtype and active order by sort, code limit 1
$$;

create or replace function _bank_account(p jsonb) returns uuid
language plpgsql stable as $$
declare v uuid;
begin
  v := nullif(p->>'bank_account_id','')::uuid;
  if v is null then v := _acct('bank'); end if;
  if not exists (select 1 from accounts where id = v and subtype = 'bank') then
    raise exception 'Choose a bank account';
  end if;
  return v;
end $$;

create or replace function _money(p_val text, p_label text) returns numeric
language plpgsql immutable as $$
declare v numeric;
begin
  if p_val is null or trim(p_val) = '' then raise exception '% is required', p_label; end if;
  v := round(replace(replace(p_val, ',', ''), '$', '')::numeric, 2);
  return v;
exception when invalid_text_representation then
  raise exception '% must be a number', p_label;
end $$;

create or replace function _date(p_val text, p_label text) returns date
language plpgsql stable as $$
begin
  if p_val is null or trim(p_val) = '' then raise exception '% is required', p_label; end if;
  return p_val::date;
exception when others then
  raise exception '% is not a valid date', p_label;
end $$;

create or replace function _fmt(p numeric) returns text
language sql immutable as $$
  select case when p < 0 then '-' else '' end || to_char(abs(p), 'FM$999,999,990.00')
$$;

create or replace function _first_open_date(p_date date) returns date
language sql stable as $$
  select greatest(p_date, coalesce((select closed_through from settings where id = 1) + 1, p_date))
$$;

create or replace function _log(p_action text, p_object text, p_id uuid, p_detail jsonb default null)
returns void language sql as $$
  insert into audit_log(action, object, object_id, detail) values (p_action, p_object, p_id, p_detail)
$$;

-- Insert a journal entry with its lines. Lines: [{account_id, fund_id, debit, credit, functional_class, memo}]
create or replace function _post_entry(p_date date, p_memo text, p_source_type text, p_source_id uuid,
                                       p_lines jsonb, p_reverses uuid default null)
returns uuid language plpgsql as $$
declare v_id uuid; l jsonb; v_d numeric; v_c numeric;
begin
  insert into journal_entries(entry_date, memo, source_type, source_id, reverses_entry_id)
  values (p_date, p_memo, p_source_type, p_source_id, p_reverses)
  returning id into v_id;
  for l in select * from jsonb_array_elements(p_lines) loop
    v_d := round(coalesce((l->>'debit')::numeric, 0), 2);
    v_c := round(coalesce((l->>'credit')::numeric, 0), 2);
    if v_d = 0 and v_c = 0 then continue; end if;
    -- normalise negatives into the opposite column
    if v_d < 0 then v_c := v_c - v_d; v_d := 0; end if;
    if v_c < 0 then v_d := v_d - v_c; v_c := 0; end if;
    if v_d > 0 and v_c > 0 then
      if v_d >= v_c then v_d := v_d - v_c; v_c := 0; else v_c := v_c - v_d; v_d := 0; end if;
      if v_d = 0 and v_c = 0 then continue; end if;
    end if;
    insert into journal_lines(entry_id, account_id, fund_id, debit, credit, functional_class, memo)
    values (v_id, (l->>'account_id')::uuid, (l->>'fund_id')::uuid, v_d, v_c,
            nullif(l->>'functional_class',''), nullif(l->>'memo',''));
  end loop;
  if not exists (select 1 from journal_lines where entry_id = v_id) then
    raise exception 'Nothing to post';
  end if;
  return v_id;
end $$;

-- Post the mirror image of an entry. Dated on the original date if that
-- period is still open, otherwise on the first open day.
create or replace function _reverse_entry(p_entry uuid, p_memo text) returns uuid
language plpgsql as $$
declare v_e journal_entries; v_new uuid;
begin
  select * into v_e from journal_entries where id = p_entry;
  if not found then raise exception 'Entry not found'; end if;
  if exists (select 1 from journal_entries where reverses_entry_id = p_entry) then
    raise exception 'Entry #% has already been reversed', v_e.entry_number;
  end if;
  insert into journal_entries(entry_date, memo, source_type, source_id, reverses_entry_id)
  values (_first_open_date(v_e.entry_date), p_memo, 'reversal', v_e.source_id, p_entry)
  returning id into v_new;
  insert into journal_lines(entry_id, account_id, fund_id, debit, credit, functional_class, memo)
  select v_new, account_id, fund_id, credit, debit, functional_class, memo
    from journal_lines where entry_id = p_entry;
  return v_new;
end $$;

-- Is a bank entry cleared on a completed reconciliation?
create or replace function _is_cleared(p_entry uuid) returns boolean
language sql stable as $$
  select exists (select 1 from reconciliation_items ri join reconciliations r on r.id = ri.reconciliation_id
                 where ri.entry_id = p_entry and r.status = 'completed')
$$;

-- Fund balance (= the fund's net assets = its share of cash) as of a date.
create or replace function _fund_balance(p_fund uuid, p_as_of date default null) returns numeric
language sql stable as $$
  select coalesce(sum(jl.debit - jl.credit), 0)
    from journal_lines jl
    join journal_entries je on je.id = jl.entry_id
    join accounts a on a.id = jl.account_id
   where jl.fund_id = p_fund and a.type in ('asset','liability')
     and (p_as_of is null or je.entry_date <= p_as_of)
$$;

create or replace function _fund_json(f funds) returns jsonb
language sql stable as $$
  select to_jsonb(f) || jsonb_build_object(
    'balance', _fund_balance(f.id),
    'effective_fee_rate', coalesce(f.admin_fee_rate, s.default_admin_fee_rate),
    'effective_fee_cap',  coalesce(f.admin_fee_cap,  s.default_admin_fee_cap))
  from settings s where s.id = 1
$$;

-- ---------------------------------------------------------------------
-- Administrative fee: 10% of each gift to a missionary fund, capped at
-- $250 per fund per calendar month (rate and cap are per-fund settings).
-- Recalculated for the whole month whenever a gift in that month is
-- posted or voided, so the cap is always applied in date order.
-- Each change is posted as an interfund entry:
--   missionary fund:  Dr 3910 Interfund-Admin Fees   Cr 1000 Checking
--   general fund:     Dr 1000 Checking               Cr 3910 Interfund-Admin Fees
-- Organization-wide the bank balance is unchanged; only fund shares move.
-- ---------------------------------------------------------------------
create or replace function _recalc_admin_fees(p_fund uuid, p_month date) returns void
language plpgsql as $$
declare
  v_f funds; v_s settings; v_rate numeric; v_cap numeric; v_running numeric := 0;
  v_desired numeric; v_delta numeric; r record; v_bank uuid; v_fee_acct uuid; v_entry uuid;
  v_start date := date_trunc('month', p_month)::date;
begin
  select * into v_f from funds where id = p_fund;
  select * into v_s from settings where id = 1;
  if v_s.admin_fee_fund_id is null or v_s.admin_fee_fund_id = p_fund then return; end if;
  v_rate := coalesce(v_f.admin_fee_rate, v_s.default_admin_fee_rate);
  v_cap  := coalesce(v_f.admin_fee_cap,  v_s.default_admin_fee_cap);
  v_bank := _acct('bank');
  v_fee_acct := _acct('interfund_fee');

  for r in
    select gl.id, gl.amount, gl.fee_exempt, gl.admin_fee, g.status, g.gift_date, g.gift_number
      from gift_lines gl join gifts g on g.id = gl.gift_id
     where gl.fund_id = p_fund
       and g.gift_date >= v_start and g.gift_date < (v_start + interval '1 month')::date
     order by g.gift_date, g.gift_number, gl.id
  loop
    if r.status = 'void' or r.fee_exempt or not v_f.admin_fee_applies then
      v_desired := 0;
    else
      v_desired := least(round(r.amount * v_rate, 2), greatest(v_cap - v_running, 0));
    end if;
    v_running := v_running + v_desired;
    v_delta := v_desired - r.admin_fee;
    if v_delta <> 0 then
      v_entry := _post_entry(
        _first_open_date(r.gift_date),
        case when v_delta > 0 then 'Administrative fee' else 'Administrative fee adjustment' end
          || ' - gift #' || r.gift_number || ' to ' || v_f.name,
        'admin_fee', r.id,
        jsonb_build_array(
          jsonb_build_object('account_id', v_fee_acct, 'fund_id', p_fund, 'debit', v_delta),
          jsonb_build_object('account_id', v_bank, 'fund_id', p_fund, 'credit', v_delta),
          jsonb_build_object('account_id', v_bank, 'fund_id', v_s.admin_fee_fund_id, 'debit', v_delta),
          jsonb_build_object('account_id', v_fee_acct, 'fund_id', v_s.admin_fee_fund_id, 'credit', v_delta)));
      update gift_lines set admin_fee = v_desired where id = r.id;
    end if;
  end loop;
end $$;

create or replace function preview_admin_fee(p jsonb) returns jsonb
language plpgsql stable as $$
declare v_f funds; v_s settings; v_rate numeric; v_cap numeric; v_mtd numeric; v_amt numeric; v_date date;
begin
  select * into v_f from funds where id = (p->>'fund_id')::uuid;
  select * into v_s from settings where id = 1;
  v_amt := coalesce(nullif(p->>'amount','')::numeric, 0);
  v_date := coalesce(nullif(p->>'gift_date','')::date, current_date);
  if v_f.id is null or not v_f.admin_fee_applies then
    return jsonb_build_object('applies', false, 'fee', 0);
  end if;
  v_rate := coalesce(v_f.admin_fee_rate, v_s.default_admin_fee_rate);
  v_cap  := coalesce(v_f.admin_fee_cap,  v_s.default_admin_fee_cap);
  select coalesce(sum(gl.admin_fee),0) into v_mtd
    from gift_lines gl join gifts g on g.id = gl.gift_id
   where gl.fund_id = v_f.id and g.status = 'posted'
     and date_trunc('month', g.gift_date) = date_trunc('month', v_date::timestamp);
  return jsonb_build_object('applies', true, 'rate', v_rate, 'cap', v_cap, 'charged_this_month', v_mtd,
     'fee', least(round(v_amt * v_rate, 2), greatest(v_cap - v_mtd, 0)));
end $$;

-- ---------------------------------------------------------------------
-- Gifts
-- p: {donor_id, gift_date, method, reference, memo,
--     lines: [{fund_id, amount, fee_exempt, memo}]}
-- ---------------------------------------------------------------------
create or replace function post_gift(p jsonb) returns jsonb
language plpgsql as $$
declare
  v_gift uuid; v_date date; v_total numeric := 0; l jsonb; v_amt numeric; v_lines jsonb := '[]';
  v_rev uuid; v_donor donors; v_entry uuid; v_undep uuid := _acct('undeposited'); r record; v_label text;
begin
  v_date := _date(p->>'gift_date', 'Gift date');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Add at least one fund designation';
  end if;
  if nullif(p->>'donor_id','') is not null then
    select * into v_donor from donors where id = (p->>'donor_id')::uuid;
    if not found then raise exception 'Donor not found'; end if;
  end if;
  v_rev := case when v_donor.donor_type in ('church','organization','foundation','business')
                then _acct('contribution_organization') else _acct('contribution_individual') end;
  if coalesce(p->>'method','') not in ('check','cash','online','ach','card','stock','other') then
    raise exception 'Choose how the gift was received';
  end if;

  for l in select * from jsonb_array_elements(p->'lines') loop
    v_amt := _money(l->>'amount', 'Amount');
    if v_amt <= 0 then raise exception 'Each designation must be more than $0.00'; end if;
    if not exists (select 1 from funds where id = (l->>'fund_id')::uuid and active) then
      raise exception 'Choose an active fund for each line';
    end if;
    v_total := v_total + v_amt;
  end loop;
  if nullif(p->>'total_amount','') is not null and _money(p->>'total_amount','Total') <> v_total then
    raise exception 'The designations ($%) do not add up to the gift total ($%)', v_total, _money(p->>'total_amount','Total');
  end if;

  insert into gifts(donor_id, gift_date, method, reference, total_amount, memo)
  values (v_donor.id, v_date, p->>'method', nullif(trim(p->>'reference'),''), v_total, nullif(trim(p->>'memo'),''))
  returning id into v_gift;

  for l in select * from jsonb_array_elements(p->'lines') loop
    insert into gift_lines(gift_id, fund_id, amount, fee_exempt, memo)
    values (v_gift, (l->>'fund_id')::uuid, _money(l->>'amount','Amount'),
            coalesce((l->>'fee_exempt')::boolean, false), nullif(trim(l->>'memo'),''));
    v_lines := v_lines
      || jsonb_build_object('account_id', v_undep, 'fund_id', l->>'fund_id', 'debit', _money(l->>'amount','Amount'))
      || jsonb_build_object('account_id', v_rev,   'fund_id', l->>'fund_id', 'credit', _money(l->>'amount','Amount'), 'memo', nullif(trim(l->>'memo'),''));
  end loop;

  v_label := 'Gift from ' || coalesce(v_donor.display_name, 'anonymous donor');
  v_entry := _post_entry(v_date, v_label, 'gift', v_gift, v_lines);
  update gifts set journal_entry_id = v_entry where id = v_gift;

  for r in select distinct fund_id from gift_lines where gift_id = v_gift loop
    perform _recalc_admin_fees(r.fund_id, v_date);
  end loop;
  return get_gift(jsonb_build_object('id', v_gift));
end $$;

create or replace function get_gift(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(g) || jsonb_build_object(
    'donor', (select to_jsonb(d) from donors d where d.id = g.donor_id),
    'deposit_number', (select deposit_number from deposits where id = g.deposit_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(gl) || jsonb_build_object('fund_name', f.name, 'fund_code', f.code) order by f.sort, f.name), '[]')
                from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id))
  from gifts g where g.id = (p->>'id')::uuid
$$;

-- Non-financial details can be corrected without voiding.
create or replace function update_gift_details(p jsonb) returns jsonb
language plpgsql as $$
begin
  update gifts set reference = nullif(trim(p->>'reference'),''), memo = nullif(trim(p->>'memo'),'')
   where id = (p->>'id')::uuid;
  perform _log('update_details', 'gift', (p->>'id')::uuid, p);
  return get_gift(p);
end $$;

-- Void a gift. Not yet deposited: the gift entry is reversed.
-- Already deposited (e.g. a returned check): revenue is reversed against
-- Checking, which shows up on the bank reconciliation like the bank's own debit.
create or replace function void_gift(p jsonb) returns jsonb
language plpgsql as $$
declare v_g gifts; v_reason text := nullif(trim(p->>'reason'),''); r record; v_lines jsonb := '[]'; v_bank uuid;
begin
  select * into v_g from gifts where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Gift not found'; end if;
  if v_g.status = 'void' then raise exception 'Gift #% is already void', v_g.gift_number; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;

  if v_g.deposit_id is null then
    perform _reverse_entry(v_g.journal_entry_id, 'VOID gift #' || v_g.gift_number || ': ' || v_reason);
  else
    select bank_account_id into v_bank from deposits where id = v_g.deposit_id;
    for r in select jl.* from journal_lines jl join accounts a on a.id = jl.account_id
              where jl.entry_id = v_g.journal_entry_id and a.type = 'revenue' loop
      v_lines := v_lines
        || jsonb_build_object('account_id', r.account_id, 'fund_id', r.fund_id, 'debit', r.credit)
        || jsonb_build_object('account_id', v_bank, 'fund_id', r.fund_id, 'credit', r.credit);
    end loop;
    perform _post_entry(_first_open_date(coalesce(nullif(p->>'void_date','')::date, current_date)),
            'VOID gift #' || v_g.gift_number || ' (after deposit): ' || v_reason,
            'reversal', v_g.id, v_lines, v_g.journal_entry_id);
  end if;
  update gifts set status = 'void', void_reason = v_reason, voided_at = now() where id = v_g.id;
  for r in select distinct fund_id from gift_lines where gift_id = v_g.id loop
    perform _recalc_admin_fees(r.fund_id, v_g.gift_date);
  end loop;
  return get_gift(p);
end $$;
