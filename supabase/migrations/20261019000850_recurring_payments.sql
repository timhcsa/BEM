-- =====================================================================
-- BEM Ledger — recurring monthly payments (e.g. missionary salary).
-- A recurring payment is a saved payment (payee, method, lines). Each
-- month the app lists the ones that are due; an administrator reviews
-- them and posts them in one step. Nothing posts on its own.
-- A month can't be posted twice for the same setup (unless the payment
-- for that month was voided). Safe to re-run.
-- =====================================================================

create table if not exists recurring_payments (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,                 -- "Ted & Marlene - monthly support"
  payee_name     text not null,
  missionary_id  uuid references missionaries(id),
  method         text not null default 'ach' check (method in ('check','ach','debit_card','wire','bank_fee','other')),
  day_of_month   int not null default 25 check (day_of_month between 1 and 28),
  start_month    date not null,                 -- first day of first month
  end_month      date,                          -- first day of last month (null = no end)
  memo           text,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  created_by     text not null default current_actor()
);

create table if not exists recurring_payment_lines (
  id               uuid primary key default gen_random_uuid(),
  recurring_id     uuid not null references recurring_payments(id) on delete cascade,
  fund_id          uuid not null references funds(id),
  account_id       uuid not null references accounts(id),
  functional_class text check (functional_class in ('program','management_general','fundraising')),
  amount           numeric(14,2) not null check (amount > 0),
  memo             text,
  sort             int not null default 0
);

create table if not exists recurring_runs (
  recurring_id     uuid not null references recurring_payments(id),
  period           text not null check (period ~ '^\d{4}-\d{2}$'),
  disbursement_id  uuid not null references disbursements(id),
  posted_at        timestamptz not null default now(),
  primary key (recurring_id, period, disbursement_id)
);

create or replace function _recurring_json(r recurring_payments) returns jsonb
language sql stable as $$
  select to_jsonb(r) || jsonb_build_object(
    'missionary_name', (select display_name from missionaries where id = r.missionary_id),
    'total', (select coalesce(sum(amount),0) from recurring_payment_lines where recurring_id = r.id),
    'lines', (select coalesce(jsonb_agg(to_jsonb(l) || jsonb_build_object('fund_name', f.name, 'account_name', a.code || ' · ' || a.name,
                 'fund_balance', _fund_balance(f.id)) order by l.sort), '[]')
                from recurring_payment_lines l join funds f on f.id = l.fund_id join accounts a on a.id = l.account_id
               where l.recurring_id = r.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('period', rr.period, 'disb_number', d.disb_number, 'date', d.disb_date,
                   'total', d.total, 'status', d.status, 'disbursement_id', d.id) order by rr.period desc, rr.posted_at desc), '[]')
                  from (select * from recurring_runs where recurring_id = r.id order by period desc limit 12) rr
                  join disbursements d on d.id = rr.disbursement_id))
$$;

create or replace function list_recurring(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(_recurring_json(r) order by r.active desc, r.day_of_month, r.name), '[]')
    from recurring_payments r
   where coalesce((p->>'include_inactive')::boolean, true) or r.active
$$;

-- p: {id?, name, payee_name, missionary_id, method, day_of_month, start_month 'YYYY-MM', end_month, memo, active,
--     lines:[{fund_id, account_id, functional_class, amount, memo}]}
create or replace function save_recurring(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid; l jsonb; i int := 0; v_start date; v_end date; v_acct accounts;
begin
  if nullif(trim(p->>'payee_name'),'') is null then raise exception 'Who is paid? Enter the payee'; end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Add at least one line'; end if;
  v_start := to_date(coalesce(nullif(p->>'start_month',''), to_char(current_date, 'YYYY-MM')) || '-01', 'YYYY-MM-DD');
  v_end := case when nullif(p->>'end_month','') is null then null else to_date((p->>'end_month') || '-01', 'YYYY-MM-DD') end;
  if v_end is not null and v_end < v_start then raise exception 'The last month is before the first month'; end if;
  for l in select * from jsonb_array_elements(p->'lines') loop
    select * into v_acct from accounts where id = nullif(l->>'account_id','')::uuid;
    if v_acct.id is null or v_acct.type <> 'expense' then raise exception 'Choose an expense category for each line'; end if;
    if nullif(l->>'fund_id','') is null then raise exception 'Choose a fund for each line'; end if;
    if _money(l->>'amount','Amount') <= 0 then raise exception 'Each line needs an amount above $0.00'; end if;
  end loop;

  if v_id is null then
    insert into recurring_payments(name, payee_name, start_month) values ('', '', v_start) returning id into v_id;
  end if;
  update recurring_payments set
    name = coalesce(nullif(trim(p->>'name'),''), trim(p->>'payee_name') || ' - monthly'),
    payee_name = trim(p->>'payee_name'),
    missionary_id = nullif(p->>'missionary_id','')::uuid,
    method = coalesce(nullif(p->>'method',''), 'ach'),
    day_of_month = least(greatest(coalesce(nullif(p->>'day_of_month','')::int, 25), 1), 28),
    start_month = v_start, end_month = v_end,
    memo = nullif(trim(p->>'memo'),''),
    active = coalesce((p->>'active')::boolean, true)
  where id = v_id;
  delete from recurring_payment_lines where recurring_id = v_id;
  for l in select * from jsonb_array_elements(p->'lines') loop
    i := i + 1;
    select * into v_acct from accounts where id = (l->>'account_id')::uuid;
    insert into recurring_payment_lines(recurring_id, fund_id, account_id, functional_class, amount, memo, sort, tax_treatment)
    values (v_id, (l->>'fund_id')::uuid, v_acct.id, coalesce(nullif(l->>'functional_class',''), v_acct.functional_class, 'program'),
            _money(l->>'amount','Amount'), nullif(trim(l->>'memo'),''), i,
            case when nullif(l->>'tax_treatment','') is not null then l->>'tax_treatment'
                 when nullif(p->>'missionary_id','') is not null then _default_tax_treatment(v_acct.id) end);
  end loop;
  perform _log('save', 'recurring_payment', v_id, p);
  return (select _recurring_json(r) from recurring_payments r where id = v_id);
end $$;

create or replace function delete_recurring(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := (p->>'id')::uuid;
begin
  if exists (select 1 from recurring_runs where recurring_id = v_id) then
    update recurring_payments set active = false where id = v_id;
    return jsonb_build_object('deactivated', true);
  end if;
  delete from recurring_payments where id = v_id;
  perform _log('delete', 'recurring_payment', v_id, null);
  return jsonb_build_object('deleted', true);
end $$;

-- What is due for a month. p: {period: 'YYYY-MM'}
create or replace function recurring_due(p jsonb) returns jsonb
language sql stable as $$
  with per as (select coalesce(nullif(p->>'period',''), to_char(current_date, 'YYYY-MM')) period),
  m as (select to_date((select period from per) || '-01', 'YYYY-MM-DD') first_day)
  select jsonb_build_object(
    'period', (select period from per),
    'items', coalesce(jsonb_agg(_recurring_json(r) || jsonb_build_object(
               'due_date', (select first_day from m) + (r.day_of_month - 1),
               'posted', exists (select 1 from recurring_runs rr join disbursements d on d.id = rr.disbursement_id
                                  where rr.recurring_id = r.id and rr.period = (select period from per) and d.status = 'posted'),
               'posted_disbursement', (select jsonb_build_object('id', d.id, 'disb_number', d.disb_number, 'date', d.disb_date, 'total', d.total)
                                         from recurring_runs rr join disbursements d on d.id = rr.disbursement_id
                                        where rr.recurring_id = r.id and rr.period = (select period from per) and d.status = 'posted' limit 1))
             order by r.day_of_month, r.name), '[]'))
  from recurring_payments r, m
  where r.active and r.start_month <= m.first_day and (r.end_month is null or r.end_month >= m.first_day)
$$;

-- Post the selected recurring payments for a month.
-- p: {period, allow_overdraft, items:[{id, date, reference}]}
-- Each item posts on its own: one problem doesn't stop the others.
create or replace function post_recurring(p jsonb) returns jsonb
language plpgsql as $$
declare it jsonb; r recurring_payments; v_period text := p->>'period'; v_disb jsonb; v_results jsonb := '[]'; v_ok int := 0;
begin
  if v_period !~ '^\d{4}-\d{2}$' then raise exception 'Choose a month'; end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items','[]')) loop
    select * into r from recurring_payments where id = (it->>'id')::uuid;
    begin
      if r.id is null then raise exception 'Recurring payment not found'; end if;
      if exists (select 1 from recurring_runs rr join disbursements d on d.id = rr.disbursement_id
                  where rr.recurring_id = r.id and rr.period = v_period and d.status = 'posted') then
        raise exception 'Already posted for %', v_period;
      end if;
      v_disb := post_disbursement(jsonb_build_object(
        'disb_date', coalesce(nullif(it->>'date',''), v_period || '-' || lpad(r.day_of_month::text, 2, '0')),
        'payee_name', r.payee_name, 'missionary_id', r.missionary_id, 'method', r.method,
        'reference', nullif(it->>'reference',''),
        'memo', coalesce(r.memo, r.name) || ' (' || to_char(to_date(v_period || '-01', 'YYYY-MM-DD'), 'Mon YYYY') || ')',
        'allow_overdraft', coalesce((p->>'allow_overdraft')::boolean, false),
        'lines', (select jsonb_agg(jsonb_build_object('fund_id', fund_id, 'account_id', account_id, 'functional_class', functional_class,
                                                      'amount', amount, 'memo', memo, 'tax_treatment', tax_treatment) order by sort)
                    from recurring_payment_lines where recurring_id = r.id)));
      insert into recurring_runs(recurring_id, period, disbursement_id) values (r.id, v_period, (v_disb->>'id')::uuid);
      v_ok := v_ok + 1;
      v_results := v_results || jsonb_build_object('id', r.id, 'name', r.name, 'ok', true, 'disb_number', v_disb->>'disb_number', 'total', v_disb->>'total');
    exception when others then
      v_results := v_results || jsonb_build_object('id', it->>'id', 'name', coalesce(r.name, '?'), 'ok', false, 'message', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('posted', v_ok, 'results', v_results);
end $$;
