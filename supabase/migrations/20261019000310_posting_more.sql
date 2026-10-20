-- =====================================================================
-- BEM Ledger — deposits, disbursements, transfers, journal entries,
-- opening balances and bank reconciliation.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Deposits: move undeposited gifts into Checking (one line on the bank
-- statement). p: {deposit_date, gift_ids:[...], memo, bank_account_id?}
-- ---------------------------------------------------------------------
create or replace function post_deposit(p jsonb) returns jsonb
language plpgsql as $$
declare v_date date; v_bank uuid; v_undep uuid := _acct('undeposited'); v_dep uuid; v_total numeric;
        v_ids uuid[]; v_lines jsonb; v_entry uuid; v_n int;
begin
  v_date := _date(p->>'deposit_date', 'Deposit date');
  v_bank := _bank_account(p);
  select array_agg(x::uuid) into v_ids from jsonb_array_elements_text(p->'gift_ids') x;
  if v_ids is null then raise exception 'Select the gifts in this deposit'; end if;
  select count(*) into v_n from gifts where id = any(v_ids) and status = 'posted' and deposit_id is null;
  if v_n <> array_length(v_ids, 1) then
    raise exception 'Some selected gifts are void or already deposited. Refresh and try again.';
  end if;
  if exists (select 1 from gifts where id = any(v_ids) and gift_date > v_date) then
    raise exception 'A gift cannot be deposited before the date it was received';
  end if;
  select sum(total_amount) into v_total from gifts where id = any(v_ids);

  insert into deposits(deposit_date, bank_account_id, total, memo)
  values (v_date, v_bank, v_total, nullif(trim(p->>'memo'),'')) returning id into v_dep;

  select jsonb_agg(x) into v_lines from (
    select jsonb_build_object('account_id', v_bank, 'fund_id', gl.fund_id, 'debit', sum(gl.amount)) x
      from gift_lines gl where gl.gift_id = any(v_ids) group by gl.fund_id
    union all
    select jsonb_build_object('account_id', v_undep, 'fund_id', gl.fund_id, 'credit', sum(gl.amount))
      from gift_lines gl where gl.gift_id = any(v_ids) group by gl.fund_id) s;

  v_entry := _post_entry(v_date, 'Deposit', 'deposit', v_dep, v_lines);
  update deposits set journal_entry_id = v_entry where id = v_dep;
  update gifts set deposit_id = v_dep where id = any(v_ids);
  return get_deposit(jsonb_build_object('id', v_dep));
end $$;

create or replace function get_deposit(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(d) || jsonb_build_object(
    'cleared', _is_cleared(d.journal_entry_id),
    'gifts', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'gift_number', g.gift_number, 'gift_date', g.gift_date,
                     'method', g.method, 'reference', g.reference, 'total_amount', g.total_amount, 'status', g.status,
                     'donor_name', coalesce(dn.display_name, 'Anonymous')) order by g.gift_date, g.gift_number), '[]')
              from gifts g left join donors dn on dn.id = g.donor_id
             where g.deposit_id = d.id or (d.status = 'void' and g.id in (
                   select (x->>'id')::uuid from jsonb_array_elements(coalesce((select detail->'gifts' from audit_log
                     where object = 'deposit' and object_id = d.id and action = 'void' order by id desc limit 1), '[]')) x))),
    'by_fund', (select coalesce(jsonb_agg(jsonb_build_object('fund_name', f.name, 'amount', jl.debit) order by f.sort, f.name), '[]')
                  from journal_lines jl join funds f on f.id = jl.fund_id
                 where jl.entry_id = d.journal_entry_id and jl.account_id = d.bank_account_id))
  from deposits d where d.id = (p->>'id')::uuid
$$;

create or replace function list_undeposited_gifts(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'gift_number', g.gift_number, 'gift_date', g.gift_date,
          'method', g.method, 'reference', g.reference, 'total_amount', g.total_amount,
          'donor_name', coalesce(d.display_name, 'Anonymous'),
          'funds', (select string_agg(f.name, ', ' order by f.sort) from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id))
          order by g.gift_date, g.gift_number), '[]')
    from gifts g left join donors d on d.id = g.donor_id
   where g.status = 'posted' and g.deposit_id is null
$$;

create or replace function list_deposits(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('cleared', _is_cleared(d.journal_entry_id),
           'gift_count', (select count(*) from gifts g where g.deposit_id = d.id))
           order by d.deposit_date desc, d.deposit_number desc), '[]')
    from (select * from deposits
           where (nullif(p->>'from','') is null or deposit_date >= (p->>'from')::date)
             and (nullif(p->>'to','') is null or deposit_date <= (p->>'to')::date)
           order by deposit_date desc, deposit_number desc
           limit coalesce(nullif(p->>'limit','')::int, 200)) d
$$;

create or replace function void_deposit(p jsonb) returns jsonb
language plpgsql as $$
declare v_d deposits; v_reason text := nullif(trim(p->>'reason'),''); v_gifts jsonb;
begin
  select * into v_d from deposits where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Deposit not found'; end if;
  if v_d.status = 'void' then raise exception 'Deposit already void'; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  if _is_cleared(v_d.journal_entry_id) then
    raise exception 'This deposit has been reconciled with a bank statement and cannot be voided';
  end if;
  if exists (select 1 from gifts where deposit_id = v_d.id and status = 'void') then
    raise exception 'A gift in this deposit was voided after deposit; correct that first';
  end if;
  select jsonb_agg(jsonb_build_object('id', id)) into v_gifts from gifts where deposit_id = v_d.id;
  perform _reverse_entry(v_d.journal_entry_id, 'VOID deposit #' || v_d.deposit_number || ': ' || v_reason);
  update gifts set deposit_id = null where deposit_id = v_d.id;
  update deposits set status = 'void', void_reason = v_reason, voided_at = now() where id = v_d.id;
  perform _log('void', 'deposit', v_d.id, jsonb_build_object('reason', v_reason, 'gifts', v_gifts));
  return get_deposit(p);
end $$;

-- ---------------------------------------------------------------------
-- Disbursements. p: {disb_date, payee_name, missionary_id, method, reference,
--   memo, bank_account_id?, allow_overdraft?, lines:[{fund_id, account_id,
--   functional_class?, amount, memo}]}
-- Refuses to take a fund below zero unless allow_overdraft is true.
-- ---------------------------------------------------------------------
create or replace function post_disbursement(p jsonb) returns jsonb
language plpgsql as $$
declare v_date date; v_bank uuid; v_id uuid; v_total numeric := 0; l jsonb; v_amt numeric; v_acct accounts;
        v_lines jsonb := '[]'; v_fc text; v_entry uuid; r record; v_short text := '';
begin
  v_date := _date(p->>'disb_date', 'Payment date');
  v_bank := _bank_account(p);
  if nullif(trim(p->>'payee_name'),'') is null then raise exception 'Payee is required'; end if;
  if coalesce(p->>'method','') not in ('check','ach','debit_card','wire','bank_fee','other') then
    raise exception 'Choose a payment method';
  end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then
    raise exception 'Add at least one expense line';
  end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    v_amt := _money(l->>'amount', 'Amount');
    if v_amt <= 0 then raise exception 'Each line must be more than $0.00'; end if;
    select * into v_acct from accounts where id = nullif(l->>'account_id','')::uuid;
    if not found or v_acct.type <> 'expense' then raise exception 'Choose an expense category for each line'; end if;
    if not exists (select 1 from funds where id = nullif(l->>'fund_id','')::uuid) then raise exception 'Choose a fund for each line'; end if;
    v_total := v_total + v_amt;
  end loop;

  -- overdraft check per fund. Missionary accounts can never go below zero:
  -- the missionary is paid once more donations have come in.
  for r in select (x->>'fund_id')::uuid fund_id, sum(_money(x->>'amount','Amount')) amt
             from jsonb_array_elements(p->'lines') x group by 1 loop
    if _fund_balance(r.fund_id) - r.amt < 0 and (select kind from funds where id = r.fund_id) = 'missionary' then
      raise exception 'Not enough in % (balance %, payment %). It can be paid once more donations come in.',
        (select name from funds where id = r.fund_id), _fmt(_fund_balance(r.fund_id)), _fmt(r.amt);
    end if;
    if _fund_balance(r.fund_id) - r.amt < 0 then
      v_short := v_short || (select name from funds where id = r.fund_id) || ' would be '
                 || _fmt(_fund_balance(r.fund_id) - r.amt) || '; ';
    end if;
  end loop;
  if v_short <> '' and not coalesce((p->>'allow_overdraft')::boolean, false) then
    raise exception 'OVERDRAFT: %', rtrim(v_short, '; ');
  end if;

  insert into disbursements(disb_date, payee_name, missionary_id, method, reference, bank_account_id, total, memo)
  values (v_date, trim(p->>'payee_name'), nullif(p->>'missionary_id','')::uuid, p->>'method',
          nullif(trim(p->>'reference'),''), v_bank, v_total, nullif(trim(p->>'memo'),''))
  returning id into v_id;
  -- link the payee (created on first use; see the tax reporting migration)
  update disbursements set payee_id = _resolve_payee(p) where id = v_id;

  for l in select * from jsonb_array_elements(p->'lines') loop
    select * into v_acct from accounts where id = (l->>'account_id')::uuid;
    v_fc := coalesce(nullif(l->>'functional_class',''), v_acct.functional_class, 'program');
    -- payments to a missionary: each line is taxable, a non-taxable reimbursement, or housing allowance
    if coalesce(l->>'tax_treatment','') not in ('', 'taxable', 'reimbursement', 'housing') then
      raise exception 'Unknown tax treatment';
    end if;
    insert into disbursement_lines(disbursement_id, fund_id, account_id, functional_class, amount, memo, tax_treatment)
    values (v_id, (l->>'fund_id')::uuid, v_acct.id, v_fc, _money(l->>'amount','Amount'), nullif(trim(l->>'memo'),''),
            case when nullif(l->>'tax_treatment','') is not null then l->>'tax_treatment'
                 when nullif(p->>'missionary_id','') is not null then _default_tax_treatment(v_acct.id) end);
    v_lines := v_lines
      || jsonb_build_object('account_id', v_acct.id, 'fund_id', l->>'fund_id', 'debit', _money(l->>'amount','Amount'),
                            'functional_class', v_fc, 'memo', nullif(trim(l->>'memo'),''))
      || jsonb_build_object('account_id', v_bank, 'fund_id', l->>'fund_id', 'credit', _money(l->>'amount','Amount'));
  end loop;
  v_entry := _post_entry(v_date, 'Payment to ' || trim(p->>'payee_name'), 'disbursement', v_id, v_lines);
  update disbursements set journal_entry_id = v_entry where id = v_id;
  return get_disbursement(jsonb_build_object('id', v_id));
end $$;

create or replace function get_disbursement(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(d) || jsonb_build_object(
    'cleared', _is_cleared(d.journal_entry_id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(dl) || jsonb_build_object('fund_name', f.name, 'account_name', a.name, 'account_code', a.code)), '[]')
                from disbursement_lines dl join funds f on f.id = dl.fund_id join accounts a on a.id = dl.account_id
               where dl.disbursement_id = d.id))
  from disbursements d where d.id = (p->>'id')::uuid
$$;

create or replace function list_disbursements(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(d) || jsonb_build_object('cleared', _is_cleared(d.journal_entry_id),
          'funds', (select string_agg(distinct f.name, ', ') from disbursement_lines dl join funds f on f.id = dl.fund_id where dl.disbursement_id = d.id),
          'categories', (select string_agg(distinct a.name, ', ') from disbursement_lines dl join accounts a on a.id = dl.account_id where dl.disbursement_id = d.id))
          order by d.disb_date desc, d.disb_number desc), '[]')
    from (select * from disbursements
           where (nullif(p->>'from','') is null or disb_date >= (p->>'from')::date)
             and (nullif(p->>'to','') is null or disb_date <= (p->>'to')::date)
             and (nullif(p->>'fund_id','') is null or id in (select disbursement_id from disbursement_lines where fund_id = (p->>'fund_id')::uuid))
           order by disb_date desc, disb_number desc
           limit coalesce(nullif(p->>'limit','')::int, 300)) d
$$;

create or replace function void_disbursement(p jsonb) returns jsonb
language plpgsql as $$
declare v_d disbursements; v_reason text := nullif(trim(p->>'reason'),'');
begin
  select * into v_d from disbursements where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Payment not found'; end if;
  if v_d.status = 'void' then raise exception 'Payment already void'; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  if _is_cleared(v_d.journal_entry_id) then
    raise exception 'This payment has cleared the bank on a completed reconciliation and cannot be voided. Record a refund or adjusting entry instead.';
  end if;
  perform _reverse_entry(v_d.journal_entry_id, 'VOID payment #' || v_d.disb_number || ': ' || v_reason);
  update disbursements set status = 'void', void_reason = v_reason, voided_at = now() where id = v_d.id;
  return get_disbursement(p);
end $$;

create or replace function list_payee_names(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(payee_name order by payee_name), '[]') from (
    select distinct payee_name from disbursements
     where nullif(p->>'q','') is null or payee_name ilike '%' || (p->>'q') || '%'
    limit 25) s
$$;

-- ---------------------------------------------------------------------
-- Interfund transfers. p: {transfer_date, from_fund_id, to_fund_id, amount, reason, allow_overdraft?}
-- ---------------------------------------------------------------------
create or replace function post_transfer(p jsonb) returns jsonb
language plpgsql as $$
declare v_date date; v_amt numeric; v_from uuid; v_to uuid; v_id uuid; v_bank uuid := _acct('bank');
        v_tr uuid := _acct('interfund_transfer'); v_entry uuid;
begin
  v_date := _date(p->>'transfer_date', 'Date');
  v_amt := _money(p->>'amount', 'Amount');
  v_from := nullif(p->>'from_fund_id','')::uuid; v_to := nullif(p->>'to_fund_id','')::uuid;
  if v_from is null or v_to is null or v_from = v_to then raise exception 'Choose two different funds'; end if;
  if v_amt <= 0 then raise exception 'Amount must be more than $0.00'; end if;
  if nullif(trim(p->>'reason'),'') is null then raise exception 'Give a reason (it appears on fund statements)'; end if;
  if _fund_balance(v_from) - v_amt < 0 and not coalesce((p->>'allow_overdraft')::boolean, false) then
    raise exception 'OVERDRAFT: % would be %', (select name from funds where id = v_from),
      _fmt(_fund_balance(v_from) - v_amt);
  end if;
  insert into transfers(transfer_date, from_fund_id, to_fund_id, amount, reason)
  values (v_date, v_from, v_to, v_amt, trim(p->>'reason')) returning id into v_id;
  v_entry := _post_entry(v_date, 'Transfer: ' || trim(p->>'reason'), 'transfer', v_id, jsonb_build_array(
    jsonb_build_object('account_id', v_tr,   'fund_id', v_from, 'debit', v_amt),
    jsonb_build_object('account_id', v_bank, 'fund_id', v_from, 'credit', v_amt),
    jsonb_build_object('account_id', v_bank, 'fund_id', v_to,   'debit', v_amt),
    jsonb_build_object('account_id', v_tr,   'fund_id', v_to,   'credit', v_amt)));
  update transfers set journal_entry_id = v_entry where id = v_id;
  return (select to_jsonb(t) from transfers t where id = v_id);
end $$;

create or replace function void_transfer(p jsonb) returns jsonb
language plpgsql as $$
declare v_t transfers; v_reason text := nullif(trim(p->>'reason'),'');
begin
  select * into v_t from transfers where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Transfer not found'; end if;
  if v_t.status = 'void' then raise exception 'Transfer already void'; end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  perform _reverse_entry(v_t.journal_entry_id, 'VOID transfer: ' || v_reason);
  update transfers set status = 'void', void_reason = v_reason, voided_at = now() where id = v_t.id;
  return (select to_jsonb(t) from transfers t where id = v_t.id);
end $$;

create or replace function list_transfers(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(t) || jsonb_build_object('from_name', ff.name, 'to_name', tf.name)
          order by t.transfer_date desc, t.created_at desc), '[]')
    from transfers t join funds ff on ff.id = t.from_fund_id join funds tf on tf.id = t.to_fund_id
   where (nullif(p->>'fund_id','') is null or (p->>'fund_id')::uuid in (t.from_fund_id, t.to_fund_id))
$$;

-- ---------------------------------------------------------------------
-- General journal entries (corrections, interest, non-cash items).
-- p: {entry_date, memo, kind:'adjustment'|'opening', lines:[{account_id, fund_id, debit, credit, functional_class, memo}]}
-- Must balance within each fund.
-- ---------------------------------------------------------------------
create or replace function post_journal_entry(p jsonb) returns jsonb
language plpgsql as $$
declare v_date date; v_kind text := coalesce(nullif(p->>'kind',''), 'adjustment'); v_entry uuid; ln jsonb;
begin
  v_date := _date(p->>'entry_date', 'Date');
  if v_kind not in ('adjustment','opening') then raise exception 'Unknown entry type'; end if;
  if nullif(trim(p->>'memo'),'') is null then raise exception 'Describe the entry (memo)'; end if;
  for ln in select * from jsonb_array_elements(p->'lines') loop
    if nullif(ln->>'account_id','') is null or nullif(ln->>'fund_id','') is null then
      raise exception 'Each line needs an account and a fund';
    end if;
  end loop;
  v_entry := _post_entry(v_date, trim(p->>'memo'), v_kind, null,
    (select jsonb_agg(l || jsonb_build_object('functional_class',
        coalesce(nullif(l->>'functional_class',''), (select functional_class from accounts where id = (l->>'account_id')::uuid))))
       from jsonb_array_elements(p->'lines') l));
  return get_entry(jsonb_build_object('id', v_entry));
end $$;

-- Opening balances: one amount per fund, all in Checking (or another bank/asset account).
-- p: {entry_date, account_id?, balances:[{fund_id, amount}]}
create or replace function post_opening_balances(p jsonb) returns jsonb
language plpgsql as $$
declare v_date date; v_acct uuid; v_lines jsonb := '[]'; b jsonb; v_amt numeric; v_f funds; v_entry uuid;
begin
  v_date := _date(p->>'entry_date', 'Date');
  v_acct := coalesce(nullif(p->>'account_id','')::uuid, _acct('bank'));
  for b in select * from jsonb_array_elements(p->'balances') loop
    v_amt := coalesce(nullif(replace(b->>'amount', ',', ''),'')::numeric, 0);
    if v_amt = 0 then continue; end if;
    select * into v_f from funds where id = (b->>'fund_id')::uuid;
    v_lines := v_lines
      || jsonb_build_object('account_id', v_acct, 'fund_id', v_f.id, 'debit', v_amt)
      || jsonb_build_object('account_id', case when v_f.restriction = 'with' then _acct('opening_with') else _acct('opening_without') end,
                            'fund_id', v_f.id, 'credit', v_amt);
  end loop;
  v_entry := _post_entry(v_date, coalesce(nullif(trim(p->>'memo'),''), 'Opening balances'), 'opening', null, v_lines);
  return get_entry(jsonb_build_object('id', v_entry));
end $$;

create or replace function void_journal_entry(p jsonb) returns jsonb
language plpgsql as $$
declare v_e journal_entries; v_reason text := nullif(trim(p->>'reason'),''); v_new uuid;
begin
  select * into v_e from journal_entries where id = (p->>'id')::uuid;
  if not found then raise exception 'Entry not found'; end if;
  if v_e.source_type not in ('adjustment','opening') then
    raise exception 'Void this from its own screen (gift, deposit, payment or transfer)';
  end if;
  if v_reason is null then raise exception 'Give a reason for voiding'; end if;
  if _is_cleared(v_e.id) then raise exception 'This entry is part of a completed bank reconciliation'; end if;
  v_new := _reverse_entry(v_e.id, 'VOID entry #' || v_e.entry_number || ': ' || v_reason);
  return get_entry(jsonb_build_object('id', v_new));
end $$;

-- Human-readable description of a journal entry.
create or replace function _entry_label(e journal_entries) returns text
language sql stable as $$
  select case e.source_type
    when 'gift' then (select coalesce(d.display_name, 'Anonymous') || ' - ' || case g.method when 'ach' then 'ACH' else g.method end || coalesce(' #' || g.reference, '')
                        from gifts g left join donors d on d.id = g.donor_id where g.id = e.source_id)
    when 'deposit' then (select 'Deposit #' || deposit_number || coalesce(' - ' || memo, '') from deposits where id = e.source_id)
    when 'bill' then (select case kind when 'expense_report' then 'Expense report' else 'Bill' end || ' #' || bill_number || ' - ' || payee_name
                             || coalesce(' (' || reference || ')', '') from bills where id = e.source_id)
    when 'bill_payment' then (select 'Bill payment - ' || payee_name || ' - ' || case method when 'check' then 'check' when 'ach' then 'EFT' else method end
                                     || coalesce(' #' || reference, '') from bill_payments where id = e.source_id)
    when 'disbursement' then (select payee_name || ' - ' || case method when 'check' then 'check' when 'ach' then 'ACH' when 'debit_card' then 'debit card'
                                     when 'wire' then 'wire' when 'bank_fee' then 'bank charge' else 'other' end
                                     || coalesce(' #' || reference, '') from disbursements where id = e.source_id)
    else e.memo end
$$;

create or replace function get_entry(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(e) || jsonb_build_object('label', _entry_label(e),
    'reversed_by', (select entry_number from journal_entries r where r.reverses_entry_id = e.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(jl) || jsonb_build_object('account_code', a.code, 'account_name', a.name, 'fund_name', f.name)
                 order by jl.debit desc, a.code), '[]')
                from journal_lines jl join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id
               where jl.entry_id = e.id))
  from journal_entries e where e.id = (p->>'id')::uuid
$$;

-- ---------------------------------------------------------------------
-- Bank reconciliation
-- ---------------------------------------------------------------------
-- Each journal entry that touched the bank, with its net bank amount.
create or replace function _bank_items(p_account uuid, p_through date)
returns table(entry_id uuid, entry_number bigint, entry_date date, source_type text, amount numeric,
              label text, reference text, reverses uuid, reversed_by uuid)
language sql stable as $$
  select e.id, e.entry_number, e.entry_date, e.source_type, sum(jl.debit - jl.credit),
         _entry_label(e),
         case e.source_type when 'disbursement' then (select reference from disbursements where id = e.source_id) end,
         e.reverses_entry_id,
         (select r.id from journal_entries r where r.reverses_entry_id = e.id limit 1)
    from journal_entries e join journal_lines jl on jl.entry_id = e.id
   where jl.account_id = p_account and e.entry_date <= p_through
   group by e.id
  having sum(jl.debit - jl.credit) <> 0
$$;

-- p: {account_id?, statement_date?}
create or replace function get_reconciliation(p jsonb) returns jsonb
language plpgsql stable as $$
declare v_acct uuid := _bank_account(p); v_open reconciliations; v_last reconciliations; v_date date;
        v_items jsonb; v_selected jsonb;
begin
  select * into v_open from reconciliations where account_id = v_acct and status = 'in_progress' order by created_at desc limit 1;
  select * into v_last from reconciliations where account_id = v_acct and status = 'completed' order by statement_date desc, completed_at desc limit 1;
  v_date := coalesce(nullif(p->>'statement_date','')::date, v_open.statement_date, current_date);

  select coalesce(jsonb_agg(jsonb_build_object('entry_id', b.entry_id, 'entry_number', b.entry_number,
            'entry_date', b.entry_date, 'source_type', b.source_type, 'amount', b.amount, 'label', b.label,
            'reference', b.reference, 'is_void_pair', (b.reverses is not null or b.reversed_by is not null))
            order by b.entry_date, b.entry_number), '[]')
    into v_items
    from _bank_items(v_acct, v_date) b
   where not _is_cleared(b.entry_id)
     -- a voided item and its reversal cancel out; hide the pair when both are on or before the statement date
     and not (b.reversed_by is not null and exists (select 1 from journal_entries r join journal_lines rl on rl.entry_id = r.id where r.id = b.reversed_by and r.entry_date <= v_date and rl.account_id = v_acct) and not _is_cleared(b.reversed_by))
     and not (b.reverses is not null and exists (select 1 from journal_entries o join journal_lines ol on ol.entry_id = o.id where o.id = b.reverses and o.entry_date <= v_date and ol.account_id = v_acct) and not _is_cleared(b.reverses));

  select coalesce(jsonb_agg(ri.entry_id), '[]') into v_selected from reconciliation_items ri where ri.reconciliation_id = v_open.id;

  return jsonb_build_object(
    'account_id', v_acct,
    'in_progress', case when v_open.id is null then null else to_jsonb(v_open) end,
    'last_completed', case when v_last.id is null then null else to_jsonb(v_last) end,
    'beginning_balance', coalesce(v_last.statement_balance, 0),
    'statement_date', v_date,
    'book_balance', (select coalesce(sum(jl.debit - jl.credit), 0) from journal_lines jl join journal_entries e on e.id = jl.entry_id
                      where jl.account_id = v_acct and e.entry_date <= v_date),
    'items', v_items,
    'selected', v_selected);
end $$;

-- p: {account_id?, statement_date, statement_balance, entry_ids:[...], complete:boolean}
create or replace function save_reconciliation(p jsonb) returns jsonb
language plpgsql as $$
declare v_acct uuid := _bank_account(p); v_r reconciliations; v_last reconciliations; v_date date; v_bal numeric;
        v_begin numeric; v_cleared numeric; v_diff numeric; v_id uuid;
begin
  v_date := _date(p->>'statement_date', 'Statement date');
  v_bal := _money(p->>'statement_balance', 'Statement ending balance');
  select * into v_last from reconciliations where account_id = v_acct and status = 'completed' order by statement_date desc, completed_at desc limit 1;
  if v_last.id is not null and v_date < v_last.statement_date then
    raise exception 'The last completed statement was dated %. Use a later statement date.', v_last.statement_date;
  end if;
  v_begin := coalesce(v_last.statement_balance, 0);

  select * into v_r from reconciliations where account_id = v_acct and status = 'in_progress' order by created_at desc limit 1;
  if v_r.id is null then
    insert into reconciliations(account_id, statement_date, statement_balance, beginning_balance)
    values (v_acct, v_date, v_bal, v_begin) returning id into v_id;
  else
    v_id := v_r.id;
    update reconciliations set statement_date = v_date, statement_balance = v_bal, beginning_balance = v_begin where id = v_id;
  end if;

  delete from reconciliation_items where reconciliation_id = v_id;
  insert into reconciliation_items(reconciliation_id, entry_id, amount)
  select v_id, b.entry_id, b.amount
    from _bank_items(v_acct, v_date) b
   where b.entry_id in (select x::uuid from jsonb_array_elements_text(coalesce(p->'entry_ids','[]')) x)
     and not _is_cleared(b.entry_id);

  if coalesce((p->>'complete')::boolean, false) then
    -- include voided pairs that cancel out within the statement period
    insert into reconciliation_items(reconciliation_id, entry_id, amount)
    select v_id, b.entry_id, b.amount from _bank_items(v_acct, v_date) b
     where not _is_cleared(b.entry_id)
       and not exists (select 1 from reconciliation_items where reconciliation_id = v_id and entry_id = b.entry_id)
       and ((b.reversed_by is not null and exists (select 1 from journal_entries r join journal_lines rl on rl.entry_id = r.id where r.id = b.reversed_by and r.entry_date <= v_date and rl.account_id = v_acct) and not _is_cleared(b.reversed_by))
         or (b.reverses is not null and exists (select 1 from journal_entries o join journal_lines ol on ol.entry_id = o.id where o.id = b.reverses and o.entry_date <= v_date and ol.account_id = v_acct) and not _is_cleared(b.reverses)));
    select coalesce(sum(amount), 0) into v_cleared from reconciliation_items where reconciliation_id = v_id;
    v_diff := v_bal - (v_begin + v_cleared);
    if v_diff <> 0 then
      raise exception 'Not balanced yet: difference of %', _fmt(v_diff);
    end if;
    update reconciliations set status = 'completed', completed_at = now(), completed_by = current_actor() where id = v_id;
  end if;
  return (select to_jsonb(r) || jsonb_build_object('cleared_total', (select coalesce(sum(amount),0) from reconciliation_items where reconciliation_id = r.id))
            from reconciliations r where r.id = v_id);
end $$;

-- Undo the most recent completed reconciliation (to fix a mistake).
create or replace function reopen_last_reconciliation(p jsonb) returns jsonb
language plpgsql as $$
declare v_acct uuid := _bank_account(p); v_last reconciliations;
begin
  if exists (select 1 from reconciliations where account_id = v_acct and status = 'in_progress') then
    raise exception 'Finish or discard the reconciliation in progress first';
  end if;
  select * into v_last from reconciliations where account_id = v_acct and status = 'completed' order by statement_date desc, completed_at desc limit 1;
  if not found then raise exception 'No completed reconciliation to reopen'; end if;
  update reconciliations set status = 'in_progress', completed_at = null, completed_by = null where id = v_last.id;
  perform _log('reopen', 'reconciliation', v_last.id, null);
  return to_jsonb(v_last);
end $$;

create or replace function discard_reconciliation(p jsonb) returns jsonb
language plpgsql as $$
begin
  delete from reconciliations where account_id = _bank_account(p) and status = 'in_progress';
  return '{}'::jsonb;
end $$;

create or replace function list_reconciliations(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('item_count', (select count(*) from reconciliation_items where reconciliation_id = r.id))
           order by r.statement_date desc), '[]')
    from reconciliations r where r.status = 'completed'
$$;
