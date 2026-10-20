-- =====================================================================
-- BEM Ledger — dashboard and financial reports (ASC 958 presentation)
-- =====================================================================

create or replace function get_dashboard(p jsonb) returns jsonb
language sql stable as $$
  with bank as (
    select coalesce(sum(jl.debit - jl.credit) filter (where a.subtype = 'bank'), 0) bank,
           coalesce(sum(jl.debit - jl.credit) filter (where a.subtype = 'undeposited'), 0) undeposited,
           coalesce(sum(jl.debit - jl.credit) filter (where a.type in ('asset','liability')), 0) net_assets
      from journal_lines jl join accounts a on a.id = jl.account_id
  ), lastrec as (
    select * from reconciliations where status = 'completed' order by statement_date desc, completed_at desc limit 1
  )
  select jsonb_build_object(
    'as_of', current_date,
    'bank_balance', (select bank from bank),
    'undeposited', (select undeposited from bank),
    'total_funds', (select net_assets from bank),
    'undeposited_count', (select count(*) from gifts where status = 'posted' and deposit_id is null),
    'unpaid_bills', (select coalesce(sum(total),0) from bills where status = 'open'),
    'unpaid_count', (select count(*) from bills where status = 'open'),
    'funds', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'code', f.code, 'name', f.name, 'kind', f.kind,
                 'restriction', f.restriction, 'active', f.active, 'balance', _fund_balance(f.id),
                 'missionary_id', m.id, 'photo_url', m.photo_url,
                 'mtd_gifts', (select coalesce(sum(gl.amount),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                                where gl.fund_id = f.id and g.status = 'posted' and g.gift_date >= date_trunc('month', current_date)),
                 'mtd_fees', (select coalesce(sum(gl.admin_fee),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                                where gl.fund_id = f.id and g.status = 'posted' and g.gift_date >= date_trunc('month', current_date)))
                 order by f.sort, m.sort nulls first, f.name), '[]')
                from funds f left join missionaries m on m.fund_id = f.id
               where f.active or _fund_balance(f.id) <> 0),
    'net_assets', jsonb_build_object(
       'without', (select coalesce(sum(_fund_balance(id)),0) from funds where restriction = 'without'),
       'with', (select coalesce(sum(_fund_balance(id)),0) from funds where restriction = 'with')),
    'month', jsonb_build_object(
       'gifts', (select coalesce(sum(total_amount),0) from gifts where status = 'posted' and gift_date >= date_trunc('month', current_date)),
       'gift_count', (select count(*) from gifts where status = 'posted' and gift_date >= date_trunc('month', current_date)),
       'expenses', (select coalesce(sum(total),0) from disbursements where status = 'posted' and disb_date >= date_trunc('month', current_date))
                 + (select coalesce(sum(total),0) from bills where status <> 'void' and bill_date >= date_trunc('month', current_date)),
       'admin_fees', (select coalesce(sum(gl.admin_fee),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                       where g.status = 'posted' and g.gift_date >= date_trunc('month', current_date))),
    'ytd', jsonb_build_object(
       'gifts', (select coalesce(sum(total_amount),0) from gifts where status = 'posted' and gift_date >= date_trunc('year', current_date)),
       'expenses', (select coalesce(sum(total),0) from disbursements where status = 'posted' and disb_date >= date_trunc('year', current_date))
                 + (select coalesce(sum(total),0) from bills where status <> 'void' and bill_date >= date_trunc('year', current_date))),
    'last_reconciliation', (select to_jsonb(lastrec) from lastrec),
    'uncleared', (select jsonb_build_object('count', count(*), 'amount', coalesce(sum(b.amount),0))
                    from _bank_items(_acct('bank'), current_date + 3650) b where not _is_cleared(b.entry_id)),
    'recent_gifts', list_gifts(jsonb_build_object('limit', 8, 'status', 'posted')),
    'closed_through', (select closed_through from settings where id = 1),
    'empty', not exists (select 1 from journal_entries))
$$;

-- Statement of Financial Position as of a date.
create or replace function report_financial_position(p jsonb) returns jsonb
language sql stable as $$
  with d as (select coalesce(nullif(p->>'as_of','')::date, current_date) as_of),
  bal as (
    select a.id, a.code, a.name, a.type, a.subtype, f.restriction, sum(jl.debit - jl.credit) amt
      from journal_lines jl join journal_entries e on e.id = jl.entry_id
      join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id, d
     where e.entry_date <= d.as_of
     group by a.id, a.code, a.name, a.type, a.subtype, f.restriction)
  select jsonb_build_object(
    'as_of', (select as_of from d),
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', amt) order by code), '[]')
                 from (select code, name, sum(amt) amt from bal where type = 'asset' group by code, name having sum(amt) <> 0) s),
    'total_assets', (select coalesce(sum(amt),0) from bal where type = 'asset'),
    'liabilities', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', -amt) order by code), '[]')
                 from (select code, name, sum(amt) amt from bal where type = 'liability' group by code, name having sum(amt) <> 0) s),
    'total_liabilities', (select coalesce(-sum(amt),0) from bal where type = 'liability'),
    'net_assets_without', (select coalesce(sum(amt),0) from bal where type in ('asset','liability') and restriction = 'without'),
    'net_assets_with', (select coalesce(sum(amt),0) from bal where type in ('asset','liability') and restriction = 'with'),
    'funds', (select coalesce(jsonb_agg(jsonb_build_object('name', f.name, 'code', f.code, 'kind', f.kind, 'restriction', f.restriction,
                 'amount', _fund_balance(f.id, (select as_of from d))) order by f.restriction desc, f.sort, f.name), '[]')
                from funds f where _fund_balance(f.id, (select as_of from d)) <> 0 or f.is_system))
$$;

-- Statement of Activities for a period, in two columns (without / with donor
-- restrictions). Net assets released from restriction = everything that
-- reduced restricted funds other than revenue: their expenses, admin fees
-- and transfers out (less transfers in from unrestricted funds).
create or replace function report_activities(p jsonb) returns jsonb
language plpgsql stable as $$
declare v_from date; v_to date; v_rev jsonb; v_exp jsonb; v_rev_wo numeric; v_rev_w numeric; v_exp_total numeric;
        v_chg_wo numeric; v_chg_w numeric; v_beg_wo numeric; v_beg_w numeric; v_released numeric;
begin
  v_to := coalesce(nullif(p->>'to','')::date, current_date);
  v_from := coalesce(nullif(p->>'from','')::date, date_trunc('year', v_to)::date);

  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'without', wo, 'with', w, 'total', wo + w) order by code), '[]'),
         coalesce(sum(wo),0), coalesce(sum(w),0)
    into v_rev, v_rev_wo, v_rev_w
    from (select a.code, a.name,
                 coalesce(sum(jl.credit - jl.debit) filter (where f.restriction = 'without'), 0) wo,
                 coalesce(sum(jl.credit - jl.debit) filter (where f.restriction = 'with'), 0) w
            from journal_lines jl join journal_entries e on e.id = jl.entry_id
            join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id
           where a.type = 'revenue' and e.entry_date between v_from and v_to
           group by a.code, a.name having sum(jl.credit - jl.debit) <> 0) s;

  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'amount', amt) order by code), '[]'), coalesce(sum(amt),0)
    into v_exp, v_exp_total
    from (select a.code, a.name, sum(jl.debit - jl.credit) amt
            from journal_lines jl join journal_entries e on e.id = jl.entry_id join accounts a on a.id = jl.account_id
           where a.type = 'expense' and e.entry_date between v_from and v_to
           group by a.code, a.name having sum(jl.debit - jl.credit) <> 0) s;

  select coalesce(sum(_fund_balance(id, v_from - 1)) filter (where restriction = 'without'), 0),
         coalesce(sum(_fund_balance(id, v_from - 1)) filter (where restriction = 'with'), 0),
         coalesce(sum(_fund_balance(id, v_to)) filter (where restriction = 'without'), 0),
         coalesce(sum(_fund_balance(id, v_to)) filter (where restriction = 'with'), 0)
    into v_beg_wo, v_beg_w, v_chg_wo, v_chg_w from funds;
  v_chg_wo := v_chg_wo - v_beg_wo;
  v_chg_w := v_chg_w - v_beg_w;
  -- opening-balance entries posted inside the period are shown separately, not as revenue
  v_released := v_rev_w - v_chg_w + coalesce((
      select sum(jl.credit - jl.debit) from journal_lines jl join journal_entries e on e.id = jl.entry_id
        join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id
       where a.subtype in ('opening_with','opening_without') and f.restriction = 'with' and e.entry_date between v_from and v_to), 0);

  return jsonb_build_object('from', v_from, 'to', v_to,
    'revenue', v_rev, 'revenue_without', v_rev_wo, 'revenue_with', v_rev_w,
    'released', v_released,
    'expenses', v_exp, 'total_expenses', v_exp_total,
    'opening_entries', jsonb_build_object(
       'without', coalesce((select sum(jl.credit - jl.debit) from journal_lines jl join journal_entries e on e.id = jl.entry_id
                     join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id
                    where a.subtype in ('opening_with','opening_without') and f.restriction = 'without' and e.entry_date between v_from and v_to), 0),
       'with', coalesce((select sum(jl.credit - jl.debit) from journal_lines jl join journal_entries e on e.id = jl.entry_id
                     join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id
                    where a.subtype in ('opening_with','opening_without') and f.restriction = 'with' and e.entry_date between v_from and v_to), 0)),
    'change_without', v_chg_wo, 'change_with', v_chg_w,
    'beginning_without', v_beg_wo, 'beginning_with', v_beg_w,
    'ending_without', v_beg_wo + v_chg_wo, 'ending_with', v_beg_w + v_chg_w);
end $$;

-- Statement of Functional Expenses: expense accounts by program / M&G / fundraising.
create or replace function report_functional_expenses(p jsonb) returns jsonb
language sql stable as $$
  with d as (select coalesce(nullif(p->>'to','')::date, current_date) t),
  r as (select coalesce(nullif(p->>'from','')::date, date_trunc('year', (select t from d))::date) f, (select t from d) t),
  x as (
    select a.code, a.name,
           coalesce(sum(jl.debit - jl.credit) filter (where coalesce(jl.functional_class, a.functional_class) = 'program'), 0) program,
           coalesce(sum(jl.debit - jl.credit) filter (where coalesce(jl.functional_class, a.functional_class) = 'management_general'), 0) mg,
           coalesce(sum(jl.debit - jl.credit) filter (where coalesce(jl.functional_class, a.functional_class) = 'fundraising'), 0) fr
      from journal_lines jl join journal_entries e on e.id = jl.entry_id join accounts a on a.id = jl.account_id, r
     where a.type = 'expense' and e.entry_date between r.f and r.t
     group by a.code, a.name having sum(jl.debit - jl.credit) <> 0)
  select jsonb_build_object('from', (select f from r), 'to', (select t from r),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'program', program,
               'management_general', mg, 'fundraising', fr, 'total', program + mg + fr) order by code), '[]') from x),
    'totals', (select jsonb_build_object('program', coalesce(sum(program),0), 'management_general', coalesce(sum(mg),0),
               'fundraising', coalesce(sum(fr),0), 'total', coalesce(sum(program + mg + fr),0)) from x))
$$;

-- Fund activity summary: one row per fund, beginning to ending balance.
create or replace function report_fund_activity(p jsonb) returns jsonb
language sql stable as $$
  with r as (select coalesce(nullif(p->>'from','')::date, date_trunc('year', coalesce(nullif(p->>'to','')::date, current_date))::date) f,
                    coalesce(nullif(p->>'to','')::date, current_date) t),
  mv as (
    select jl.fund_id,
      sum(case when a.type = 'revenue' then jl.credit - jl.debit else 0 end) revenue,
      sum(case when a.subtype = 'interfund_fee' then jl.credit - jl.debit else 0 end) admin_fees,
      sum(case when a.subtype = 'interfund_transfer' then jl.credit - jl.debit else 0 end) transfers,
      sum(case when a.type = 'expense' then jl.debit - jl.credit else 0 end) expenses,
      sum(case when a.subtype in ('opening_with','opening_without') then jl.credit - jl.debit else 0 end) opening
      from journal_lines jl join journal_entries e on e.id = jl.entry_id join accounts a on a.id = jl.account_id, r
     where e.entry_date between r.f and r.t
     group by jl.fund_id)
  select jsonb_build_object('from', (select f from r), 'to', (select t from r),
    'rows', coalesce(jsonb_agg(jsonb_build_object('fund_id', f.id, 'code', f.code, 'name', f.name, 'kind', f.kind, 'restriction', f.restriction,
              'beginning', _fund_balance(f.id, (select f from r) - 1),
              'revenue', coalesce(mv.revenue,0), 'admin_fees', coalesce(mv.admin_fees,0), 'transfers', coalesce(mv.transfers,0),
              'expenses', coalesce(mv.expenses,0), 'opening', coalesce(mv.opening,0),
              'ending', _fund_balance(f.id, (select t from r))) order by f.sort, f.name), '[]'))
    from funds f left join mv on mv.fund_id = f.id
   where f.active or mv.fund_id is not null or _fund_balance(f.id, (select t from r)) <> 0
$$;

-- General ledger detail. p: {from, to, account_id, fund_id}
create or replace function report_general_ledger(p jsonb) returns jsonb
language sql stable as $$
  with r as (select coalesce(nullif(p->>'from','')::date, date_trunc('month', current_date)::date) f,
                    coalesce(nullif(p->>'to','')::date, current_date) t)
  select jsonb_build_object('from', (select f from r), 'to', (select t from r),
    'rows', coalesce(jsonb_agg(jsonb_build_object('entry_id', e.id, 'entry_number', e.entry_number, 'entry_date', e.entry_date,
              'source_type', e.source_type, 'label', _entry_label(e), 'account_code', a.code, 'account_name', a.name,
              'fund_name', f.name, 'debit', jl.debit, 'credit', jl.credit, 'memo', jl.memo, 'created_by', e.created_by)
              order by e.entry_date, e.entry_number, jl.debit desc), '[]'))
    from journal_entries e join journal_lines jl on jl.entry_id = e.id
    join accounts a on a.id = jl.account_id join funds f on f.id = jl.fund_id, r
   where e.entry_date between r.f and r.t
     and (nullif(p->>'account_id','') is null or jl.account_id = (p->>'account_id')::uuid)
     and (nullif(p->>'fund_id','') is null or jl.fund_id = (p->>'fund_id')::uuid)
$$;

-- Trial balance as of a date (debits = credits check).
create or replace function report_trial_balance(p jsonb) returns jsonb
language sql stable as $$
  with r as (select coalesce(nullif(p->>'as_of','')::date, current_date) t),
  x as (select a.code, a.name, a.type, sum(jl.debit) d, sum(jl.credit) c
          from journal_lines jl join journal_entries e on e.id = jl.entry_id join accounts a on a.id = jl.account_id, r
         where e.entry_date <= r.t group by a.code, a.name, a.type)
  select jsonb_build_object('as_of', (select t from r),
    'rows', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', name, 'type', type,
              'debit', greatest(d - c, 0), 'credit', greatest(c - d, 0)) order by code), '[]') from x where d <> c),
    'total_debit', (select coalesce(sum(greatest(d - c, 0)),0) from x),
    'total_credit', (select coalesce(sum(greatest(c - d, 0)),0) from x))
$$;

-- Annual giving statements (IRS written acknowledgment).
-- p: {year, donor_id?} -> one statement per donor with gifts that year.
create or replace function report_donor_statements(p jsonb) returns jsonb
language sql stable as $$
  with y as (select coalesce(nullif(p->>'year','')::int, extract(year from current_date)::int - 1) yr)
  select jsonb_build_object('year', (select yr from y), 'settings', (select to_jsonb(s) from settings s where id = 1),
    'statements', coalesce(jsonb_agg(jsonb_build_object('donor', to_jsonb(d), 'total', t.total,
       'gifts', (select jsonb_agg(jsonb_build_object('gift_number', g.gift_number, 'gift_date', g.gift_date, 'method', g.method,
                    'reference', g.reference, 'amount', g.total_amount,
                    'designation', (select string_agg(f.name, ', ' order by f.sort) from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id))
                    order by g.gift_date, g.gift_number)
                   from gifts g, y where g.donor_id = d.id and g.status = 'posted' and extract(year from g.gift_date) = y.yr))
       order by d.sort_name), '[]'))
  from donors d
  join (select g.donor_id, sum(g.total_amount) total from gifts g, y
         where g.status = 'posted' and extract(year from g.gift_date) = y.yr group by g.donor_id) t on t.donor_id = d.id
  where nullif(p->>'donor_id','') is null or d.id = (p->>'donor_id')::uuid
$$;
