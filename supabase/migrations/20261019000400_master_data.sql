-- =====================================================================
-- BEM Ledger — donors, funds, missionaries, accounts, settings, lookups.
-- =====================================================================

create or replace function get_lookups(p jsonb) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'settings', (select to_jsonb(s) from settings s where id = 1),
    'funds', (select coalesce(jsonb_agg(_fund_json(f) || jsonb_build_object(
                 'missionary_id', m.id, 'photo_url', m.photo_url) order by f.sort, m.sort nulls first, f.name), '[]')
                from funds f left join missionaries m on m.fund_id = f.id),
    'accounts', (select coalesce(jsonb_agg(to_jsonb(a) order by a.code), '[]') from accounts a),
    'missionaries', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'display_name', m.display_name,
                       'fund_id', m.fund_id, 'active', m.active, 'photo_url', m.photo_url) order by m.sort, m.display_name), '[]')
                       from missionaries m))
$$;

-- ---------------------------------------------------------------------
-- Donors
-- ---------------------------------------------------------------------
create or replace function search_donors(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(x order by x->>'sort_name'), '[]') from (
    select to_jsonb(d) || jsonb_build_object(
             'last_gift_date', (select max(gift_date) from gifts g where g.donor_id = d.id and g.status = 'posted'),
             'ytd_total', (select coalesce(sum(total_amount),0) from gifts g where g.donor_id = d.id and g.status = 'posted'
                            and g.gift_date >= date_trunc('year', current_date))) x
      from donors d
     where (coalesce((p->>'include_inactive')::boolean, false) or d.active)
       and (nullif(trim(p->>'q'),'') is null
            or d.display_name ilike '%' || trim(p->>'q') || '%'
            or d.sort_name ilike '%' || trim(p->>'q') || '%'
            or coalesce(d.email,'') ilike '%' || trim(p->>'q') || '%'
            or coalesce(d.city,'') ilike '%' || trim(p->>'q') || '%'
            or coalesce(d.church_affiliation,'') ilike '%' || trim(p->>'q') || '%'
            or d.donor_number::text = trim(p->>'q'))
     order by d.sort_name
     limit coalesce(nullif(p->>'limit','')::int, 50)) s
$$;

create or replace function get_donor(p jsonb) returns jsonb
language sql stable as $$
  select to_jsonb(d) || jsonb_build_object(
    'gifts', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'gift_number', g.gift_number, 'gift_date', g.gift_date,
               'method', g.method, 'reference', g.reference, 'total_amount', g.total_amount, 'status', g.status,
               'funds', (select string_agg(f.name || case when gl_count.n > 1 then ' ' || to_char(gl.amount, 'FM$999,990.00') else '' end, ', ' order by f.sort)
                           from gift_lines gl join funds f on f.id = gl.fund_id
                           cross join (select count(*) n from gift_lines where gift_id = g.id) gl_count
                          where gl.gift_id = g.id))
               order by g.gift_date desc, g.gift_number desc), '[]')
              from gifts g where g.donor_id = d.id),
    'by_year', (select coalesce(jsonb_agg(jsonb_build_object('year', y, 'total', t, 'count', n) order by y desc), '[]')
                  from (select extract(year from gift_date)::int y, sum(total_amount) t, count(*) n
                          from gifts where donor_id = d.id and status = 'posted' group by 1) s),
    'lifetime_total', (select coalesce(sum(total_amount),0) from gifts where donor_id = d.id and status = 'posted'))
  from donors d where d.id = (p->>'id')::uuid
$$;

create or replace function save_donor(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid; d jsonb := p;
begin
  if v_id is null then
    insert into donors(donor_type, first_name, last_name, spouse_name, organization_name, salutation, email, phone,
                       address_line1, address_line2, city, state, postal_code, country, church_affiliation, contact_name,
                       receipt_preference, is_anonymous, notes, active, display_name, sort_name)
    values (coalesce(nullif(d->>'donor_type',''),'individual'), nullif(trim(d->>'first_name'),''), nullif(trim(d->>'last_name'),''),
            nullif(trim(d->>'spouse_name'),''), nullif(trim(d->>'organization_name'),''), nullif(trim(d->>'salutation'),''),
            nullif(trim(d->>'email'),''), nullif(trim(d->>'phone'),''), nullif(trim(d->>'address_line1'),''),
            nullif(trim(d->>'address_line2'),''), nullif(trim(d->>'city'),''), nullif(trim(d->>'state'),''),
            nullif(trim(d->>'postal_code'),''), coalesce(nullif(trim(d->>'country'),''),'US'),
            nullif(trim(d->>'church_affiliation'),''), nullif(trim(d->>'contact_name'),''),
            coalesce(nullif(d->>'receipt_preference',''),'email'), coalesce((d->>'is_anonymous')::boolean,false),
            nullif(trim(d->>'notes'),''), coalesce((d->>'active')::boolean,true), '', '')
    returning id into v_id;
    perform _log('create', 'donor', v_id, null);
  else
    update donors set donor_type = coalesce(nullif(d->>'donor_type',''),'individual'),
      first_name = nullif(trim(d->>'first_name'),''), last_name = nullif(trim(d->>'last_name'),''),
      spouse_name = nullif(trim(d->>'spouse_name'),''), organization_name = nullif(trim(d->>'organization_name'),''),
      salutation = nullif(trim(d->>'salutation'),''), email = nullif(trim(d->>'email'),''), phone = nullif(trim(d->>'phone'),''),
      address_line1 = nullif(trim(d->>'address_line1'),''), address_line2 = nullif(trim(d->>'address_line2'),''),
      city = nullif(trim(d->>'city'),''), state = nullif(trim(d->>'state'),''), postal_code = nullif(trim(d->>'postal_code'),''),
      country = coalesce(nullif(trim(d->>'country'),''),'US'), church_affiliation = nullif(trim(d->>'church_affiliation'),''),
      contact_name = nullif(trim(d->>'contact_name'),''),
      receipt_preference = coalesce(nullif(d->>'receipt_preference',''),'email'),
      is_anonymous = coalesce((d->>'is_anonymous')::boolean,false), notes = nullif(trim(d->>'notes'),''),
      active = coalesce((d->>'active')::boolean,true)
    where id = v_id;
    if not found then raise exception 'Donor not found'; end if;
    perform _log('update', 'donor', v_id, null);
  end if;
  return (select to_jsonb(x) from donors x where id = v_id);
end $$;

-- ---------------------------------------------------------------------
-- Funds & missionaries
-- ---------------------------------------------------------------------
create or replace function save_fund(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_old funds;
begin
  if nullif(trim(p->>'name'),'') is null or nullif(trim(p->>'code'),'') is null then
    raise exception 'Fund needs a code and a name';
  end if;
  if v_id is null then
    insert into funds(code, name, kind, restriction, admin_fee_applies, admin_fee_rate, admin_fee_cap, description, active, sort)
    values (upper(trim(p->>'code')), trim(p->>'name'), coalesce(nullif(p->>'kind',''),'other'),
            coalesce(nullif(p->>'restriction',''),'with'), coalesce((p->>'admin_fee_applies')::boolean,false),
            nullif(p->>'admin_fee_rate','')::numeric, nullif(p->>'admin_fee_cap','')::numeric,
            nullif(trim(p->>'description'),''), coalesce((p->>'active')::boolean,true),
            coalesce(nullif(p->>'sort','')::int, 100))
    returning id into v_id;
  else
    select * into v_old from funds where id = v_id;
    if v_old.restriction <> coalesce(nullif(p->>'restriction',''), v_old.restriction)
       and exists (select 1 from journal_lines where fund_id = v_id) then
      raise exception 'This fund already has activity, so its restriction class cannot be changed. Create a new fund and transfer the balance, or ask your CPA about a reclassification.';
    end if;
    update funds set code = upper(trim(p->>'code')), name = trim(p->>'name'),
      kind = case when is_system then kind else coalesce(nullif(p->>'kind',''), kind) end,
      restriction = coalesce(nullif(p->>'restriction',''), restriction),
      admin_fee_applies = coalesce((p->>'admin_fee_applies')::boolean, admin_fee_applies),
      admin_fee_rate = nullif(p->>'admin_fee_rate','')::numeric,
      admin_fee_cap = nullif(p->>'admin_fee_cap','')::numeric,
      description = nullif(trim(p->>'description'),''),
      active = case when is_system then true else coalesce((p->>'active')::boolean, active) end,
      sort = coalesce(nullif(p->>'sort','')::int, sort)
    where id = v_id;
  end if;
  perform _log('save', 'fund', v_id, p);
  return (select _fund_json(f) from funds f where id = v_id);
end $$;

-- Creates the missionary's fund automatically when new.
create or replace function save_missionary(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_fund uuid; v_code text; v_name text := nullif(trim(p->>'display_name'),'');
begin
  if v_name is null then raise exception 'Missionary name is required'; end if;
  if v_id is null then
    v_code := coalesce(nullif(upper(trim(p->>'fund_code')),''),
                       'M-' || upper(left(regexp_replace(split_part(v_name, ' ', array_length(regexp_split_to_array(v_name, '\s+'),1)), '[^A-Za-z]', '', 'g'), 10)));
    while exists (select 1 from funds where code = v_code) loop v_code := v_code || '2'; end loop;
    insert into funds(code, name, kind, restriction, admin_fee_applies, sort, description)
    values (v_code, v_name, 'missionary', coalesce(nullif(p->>'restriction',''),'with'),
            coalesce((p->>'admin_fee_applies')::boolean, true), 50, 'Missionary support account')
    returning id into v_fund;
    insert into missionaries(fund_id, display_name, role_title, photo_url, email, phone, address, start_date, bio, active, sort)
    values (v_fund, v_name, nullif(trim(p->>'role_title'),''), nullif(p->>'photo_url',''), nullif(trim(p->>'email'),''),
            nullif(trim(p->>'phone'),''), nullif(trim(p->>'address'),''), nullif(p->>'start_date','')::date,
            nullif(trim(p->>'bio'),''), coalesce((p->>'active')::boolean,true), coalesce(nullif(p->>'sort','')::int, 50))
    returning id into v_id;
  else
    update missionaries set display_name = v_name, role_title = nullif(trim(p->>'role_title'),''),
      photo_url = case when p ? 'photo_url' then nullif(p->>'photo_url','') else photo_url end,
      email = nullif(trim(p->>'email'),''), phone = nullif(trim(p->>'phone'),''), address = nullif(trim(p->>'address'),''),
      start_date = nullif(p->>'start_date','')::date, bio = nullif(trim(p->>'bio'),''),
      active = coalesce((p->>'active')::boolean, active), sort = coalesce(nullif(p->>'sort','')::int, sort)
    where id = v_id returning fund_id into v_fund;
    if v_fund is null then raise exception 'Missionary not found'; end if;
    update funds set name = v_name, active = coalesce((p->>'active')::boolean, active) where id = v_fund;
    if p ? 'admin_fee_applies' then
      update funds set admin_fee_applies = (p->>'admin_fee_applies')::boolean,
                       admin_fee_rate = nullif(p->>'admin_fee_rate','')::numeric,
                       admin_fee_cap  = nullif(p->>'admin_fee_cap','')::numeric where id = v_fund;
    end if;
  end if;
  perform _log('save', 'missionary', v_id, p - 'photo_url');
  return (select to_jsonb(m) from missionaries m where id = v_id);
end $$;

create or replace function list_missionaries(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object(
      'fund', _fund_json(f),
      'balance', _fund_balance(f.id),
      'cash', _fund_cash(f.id),
      'unpaid', _fund_unpaid(f.id),
      'mtd_gifts', (select coalesce(sum(gl.amount),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                     where gl.fund_id = f.id and g.status = 'posted' and g.gift_date >= date_trunc('month', current_date)),
      'ytd_gifts', (select coalesce(sum(gl.amount),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                     where gl.fund_id = f.id and g.status = 'posted' and g.gift_date >= date_trunc('year', current_date)),
      'mtd_fees', (select coalesce(sum(gl.admin_fee),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                     where gl.fund_id = f.id and g.status = 'posted' and g.gift_date >= date_trunc('month', current_date)))
      order by m.active desc, m.sort, m.display_name), '[]')
    from missionaries m join funds f on f.id = m.fund_id
   where coalesce((p->>'include_inactive')::boolean, false) or m.active
$$;

-- Full fund statement for any fund (missionary page uses this).
-- p: {fund_id | missionary_id, from, to}
create or replace function get_fund_account(p jsonb) returns jsonb
language plpgsql stable as $$
declare v_fund uuid; v_from date; v_to date; v_open numeric; v_rows jsonb; v_m jsonb;
begin
  v_fund := coalesce(nullif(p->>'fund_id','')::uuid, (select fund_id from missionaries where id = nullif(p->>'missionary_id','')::uuid));
  if v_fund is null then raise exception 'Fund not found'; end if;
  v_to := coalesce(nullif(p->>'to','')::date, current_date);
  v_from := coalesce(nullif(p->>'from','')::date, date_trunc('year', v_to)::date);
  v_open := _fund_balance(v_fund, v_from - 1);

  select coalesce(jsonb_agg(x order by (x->>'entry_date')::date, (x->>'entry_number')::bigint), '[]') into v_rows from (
    select jsonb_build_object(
      'entry_id', e.id, 'entry_number', e.entry_number, 'entry_date', e.entry_date, 'source_type', e.source_type,
      'source_id', e.source_id,
      'kind', case
         when e.source_type = 'gift' then 'gift'
         when e.source_type = 'admin_fee' then 'admin_fee'
         when e.source_type = 'disbursement' then 'expense'
         when e.source_type = 'bill' then 'expense'
         when e.source_type = 'transfer' then 'transfer'
         when e.source_type = 'opening' then 'opening'
         when e.source_type = 'reversal' then 'void'
         else 'adjustment' end,
      'description', _entry_label(e),
      'detail', case when e.source_type = 'disbursement' then
                       (select string_agg(a.name || coalesce(' - ' || dl.memo, '')
                                 || case dl.tax_treatment when 'taxable' then ' (taxable)' when 'reimbursement' then ' (non-taxable reimbursement)'
                                                          when 'housing' then ' (housing allowance)' else '' end, '; ')
                          from disbursement_lines dl join accounts a on a.id = dl.account_id
                         where dl.disbursement_id = e.source_id and dl.fund_id = v_fund)
                     when e.source_type = 'bill' then
                       (select string_agg(a.name || coalesce(' - ' || bl.memo, '')
                                 || case when bl.quantity is not null then ' (' || bl.quantity || ' mi)' else '' end
                                 || case bl.tax_treatment when 'taxable' then ' (taxable)' when 'reimbursement' then ' (reimbursement)'
                                                          when 'housing' then ' (housing allowance)' else '' end
                                 || case when b.status = 'open' then ' - UNPAID' else '' end, '; ')
                          from bill_lines bl join accounts a on a.id = bl.account_id join bills b on b.id = bl.bill_id
                         where bl.bill_id = e.source_id and bl.fund_id = v_fund)
                     when e.source_type = 'gift' then
                       (select string_agg(memo, '; ') from journal_lines jl2 where jl2.entry_id = e.id and jl2.fund_id = v_fund and memo is not null)
                     else null end,
      'amount', sum(case when a.type in ('asset','liability') then jl.debit - jl.credit else 0 end)) x
    from journal_entries e
    join journal_lines jl on jl.entry_id = e.id and jl.fund_id = v_fund
    join accounts a on a.id = jl.account_id
   where e.entry_date between v_from and v_to
     and e.source_type <> 'deposit'      -- deposits only move money between bank accounts
   group by e.id
  having sum(case when a.type in ('asset','liability') then jl.debit - jl.credit else 0 end) <> 0) s;

  select jsonb_build_object('id', m.id, 'display_name', m.display_name, 'role_title', m.role_title, 'photo_url', m.photo_url,
                            'email', m.email, 'phone', m.phone, 'address', m.address, 'start_date', m.start_date, 'bio', m.bio,
                            'active', m.active, 'sort', m.sort)
    into v_m from missionaries m where m.fund_id = v_fund;

  return jsonb_build_object(
    'fund', (select _fund_json(f) from funds f where id = v_fund),
    'missionary', v_m,
    'from', v_from, 'to', v_to,
    'opening_balance', v_open,
    'closing_balance', _fund_balance(v_fund, v_to),
    'current_balance', _fund_balance(v_fund),
    'cash', _fund_cash(v_fund),
    'unpaid', _fund_unpaid(v_fund),
    'unpaid_bills', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'bill_number', b.bill_number, 'kind', b.kind,
                        'bill_date', b.bill_date, 'reference', b.reference, 'amount', s.amt) order by b.bill_date), '[]')
                       from bills b join (select bill_id, sum(amount) amt from bill_lines where fund_id = v_fund group by bill_id) s on s.bill_id = b.id
                      where b.status = 'open'),
    'rows', v_rows,
    'totals', jsonb_build_object(
       'gifts', (select coalesce(sum((r->>'amount')::numeric),0) from jsonb_array_elements(v_rows) r where r->>'kind' = 'gift'),
       'admin_fees', (select coalesce(sum((r->>'amount')::numeric),0) from jsonb_array_elements(v_rows) r where r->>'kind' = 'admin_fee'),
       'expenses', (select coalesce(sum((r->>'amount')::numeric),0) from jsonb_array_elements(v_rows) r where r->>'kind' = 'expense'),
       'transfers', (select coalesce(sum((r->>'amount')::numeric),0) from jsonb_array_elements(v_rows) r where r->>'kind' = 'transfer'),
       'other', (select coalesce(sum((r->>'amount')::numeric),0) from jsonb_array_elements(v_rows) r where r->>'kind' not in ('gift','admin_fee','expense','transfer'))),
    'monthly', (select coalesce(jsonb_agg(jsonb_build_object('month', to_char(mo, 'YYYY-MM'),
                   'gifts', (select coalesce(sum(gl.amount),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                              where gl.fund_id = v_fund and g.status = 'posted' and date_trunc('month', g.gift_date) = mo),
                   'fees', (select coalesce(sum(gl.admin_fee),0) from gift_lines gl join gifts g on g.id = gl.gift_id
                              where gl.fund_id = v_fund and g.status = 'posted' and date_trunc('month', g.gift_date) = mo),
                   'expenses', (select coalesce(sum(dl.amount),0) from disbursement_lines dl join disbursements d on d.id = dl.disbursement_id
                              where dl.fund_id = v_fund and d.status = 'posted' and date_trunc('month', d.disb_date) = mo)
                             + (select coalesce(sum(bl.amount),0) from bill_lines bl join bills b on b.id = bl.bill_id
                              where bl.fund_id = v_fund and b.status <> 'void' and date_trunc('month', b.bill_date) = mo))
                   order by mo), '[]')
                  from generate_series(date_trunc('month', v_to) - interval '11 months', date_trunc('month', v_to), interval '1 month') mo),
    'donors', (select coalesce(jsonb_agg(jsonb_build_object('donor_id', d.id, 'name', coalesce(d.display_name, 'Anonymous'),
                   'is_anonymous', coalesce(d.is_anonymous, false), 'total', t, 'count', n, 'last_gift', lg) order by t desc), '[]')
                 from (select g.donor_id, sum(gl.amount) t, count(distinct g.id) n, max(g.gift_date) lg
                         from gift_lines gl join gifts g on g.id = gl.gift_id
                        where gl.fund_id = v_fund and g.status = 'posted' and g.gift_date between v_from and v_to
                        group by g.donor_id) s left join donors d on d.id = s.donor_id));
end $$;

-- ---------------------------------------------------------------------
-- Gifts register
-- p: {from, to, fund_id, donor_id, status, q, limit}
-- ---------------------------------------------------------------------
create or replace function list_gifts(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(x order by (x->>'gift_date')::date desc, (x->>'gift_number')::bigint desc), '[]') from (
    select jsonb_build_object('id', g.id, 'gift_number', g.gift_number, 'gift_date', g.gift_date, 'method', g.method,
             'reference', g.reference, 'total_amount', g.total_amount, 'status', g.status, 'memo', g.memo,
             'donor_id', g.donor_id, 'donor_name', coalesce(d.display_name, 'Anonymous'),
             'deposit_number', dep.deposit_number, 'deposited', g.deposit_id is not null,
             'admin_fee', (select coalesce(sum(admin_fee),0) from gift_lines where gift_id = g.id),
             'funds', (select string_agg(f.name, ', ' order by f.sort, f.name) from gift_lines gl join funds f on f.id = gl.fund_id where gl.gift_id = g.id)) x
      from gifts g left join donors d on d.id = g.donor_id left join deposits dep on dep.id = g.deposit_id
     where (nullif(p->>'from','') is null or g.gift_date >= (p->>'from')::date)
       and (nullif(p->>'to','') is null or g.gift_date <= (p->>'to')::date)
       and (nullif(p->>'donor_id','') is null or g.donor_id = (p->>'donor_id')::uuid)
       and (nullif(p->>'fund_id','') is null or exists (select 1 from gift_lines gl where gl.gift_id = g.id and gl.fund_id = (p->>'fund_id')::uuid))
       and (nullif(p->>'status','') is null or g.status = p->>'status')
       and (nullif(trim(p->>'q'),'') is null or d.display_name ilike '%' || trim(p->>'q') || '%' or g.reference ilike '%' || trim(p->>'q') || '%'
            or g.gift_number::text = trim(p->>'q'))
     order by g.gift_date desc, g.gift_number desc
     limit coalesce(nullif(p->>'limit','')::int, 300)) s
$$;

-- ---------------------------------------------------------------------
-- Accounts & settings
-- ---------------------------------------------------------------------
create or replace function save_account(p jsonb) returns jsonb
language plpgsql as $$
declare v_id uuid := nullif(p->>'id','')::uuid;
begin
  if nullif(trim(p->>'code'),'') is null or nullif(trim(p->>'name'),'') is null then raise exception 'Account needs a number and a name'; end if;
  if v_id is null then
    if coalesce(p->>'type','') not in ('asset','liability','revenue','expense') then raise exception 'Choose an account type'; end if;
    insert into accounts(code, name, type, subtype, functional_class, description, sort)
    values (trim(p->>'code'), trim(p->>'name'), p->>'type',
            case p->>'type' when 'expense' then 'expense' when 'revenue' then coalesce(nullif(p->>'subtype',''),'other_revenue')
                            when 'asset' then case when p->>'subtype' = 'bank' then 'bank' else 'other' end else 'other' end,
            case when p->>'type' = 'expense' then coalesce(nullif(p->>'functional_class',''),'management_general') end,
            nullif(trim(p->>'description'),''), coalesce(nullif(p->>'sort','')::int, (trim(p->>'code'))::int))
    returning id into v_id;
  else
    update accounts set code = case when is_system then code else trim(p->>'code') end, name = trim(p->>'name'),
      functional_class = case when type = 'expense' then coalesce(nullif(p->>'functional_class',''), functional_class) end,
      description = nullif(trim(p->>'description'),''),
      active = case when is_system then true else coalesce((p->>'active')::boolean, active) end
    where id = v_id;
  end if;
  perform _log('save', 'account', v_id, p);
  return (select to_jsonb(a) from accounts a where id = v_id);
exception when invalid_text_representation then
  raise exception 'Account number must be numeric';
end $$;

create or replace function save_settings(p jsonb) returns jsonb
language plpgsql as $$
begin
  update settings set
    org_name = coalesce(nullif(trim(p->>'org_name'),''), org_name),
    ein = nullif(trim(p->>'ein'),''), address = nullif(trim(p->>'address'),''), phone = nullif(trim(p->>'phone'),''),
    website = nullif(trim(p->>'website'),''),
    logo_url = case when p ? 'logo_url' then nullif(p->>'logo_url','') else logo_url end,
    fiscal_year_start_month = coalesce(nullif(p->>'fiscal_year_start_month','')::int, fiscal_year_start_month),
    default_admin_fee_rate = coalesce(nullif(p->>'default_admin_fee_rate','')::numeric, default_admin_fee_rate),
    default_admin_fee_cap = coalesce(nullif(p->>'default_admin_fee_cap','')::numeric, default_admin_fee_cap),
    form1099_threshold = coalesce(nullif(p->>'form1099_threshold','')::numeric, form1099_threshold),
    mileage_rate = coalesce(nullif(p->>'mileage_rate','')::numeric, mileage_rate),
    receipt_signer = nullif(trim(p->>'receipt_signer'),''), receipt_note = nullif(trim(p->>'receipt_note'),''),
    updated_at = now()
  where id = 1;
  perform _log('save', 'settings', null, p - 'logo_url');
  return (select to_jsonb(s) from settings s where id = 1);
end $$;

-- Close (lock) the books through a date, or reopen by passing an earlier date / null.
create or replace function set_closed_through(p jsonb) returns jsonb
language plpgsql as $$
declare v_old date;
begin
  select closed_through into v_old from settings where id = 1;
  update settings set closed_through = nullif(p->>'closed_through','')::date, updated_at = now() where id = 1;
  perform _log('set_closed_through', 'settings', null, jsonb_build_object('from', v_old, 'to', nullif(p->>'closed_through','')));
  return (select to_jsonb(s) from settings s where id = 1);
end $$;

create or replace function list_audit_log(p jsonb) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]')
    from (select * from audit_log order by id desc limit coalesce(nullif(p->>'limit','')::int, 200)) a
$$;

-- Everything, as JSON, for backup or for moving local data to Supabase.
create or replace function export_all_data(p jsonb) returns jsonb
language plpgsql stable as $$
declare t text; v jsonb; r jsonb := '{}';
begin
  foreach t in array array['accounts','funds','missionaries','payees','recurring_payments','recurring_payment_lines','donors','journal_entries','journal_lines','deposits','gifts','gift_lines',
                           'disbursements','disbursement_lines','recurring_runs','bill_payments','bills','bill_lines','transfers','reconciliations','reconciliation_items',
                           'bank_transactions','audit_log','settings'] loop
    execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from %I x', t) into v;
    r := r || jsonb_build_object(t, v);
  end loop;
  return r;
end $$;
