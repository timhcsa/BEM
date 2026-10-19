-- Accounting rule tests. Run against a database that has the migrations
-- (and optionally sample data) loaded:  psql -f supabase/tests/accounting_tests.sql
-- Everything runs inside a transaction that is rolled back.
begin;
do $$
declare
  v_m jsonb; v_f uuid; v_d uuid; g1 jsonb; g2 jsonb; g3 jsonb; g4 jsonb; v numeric; v_tb jsonb; v_dash jsonb;
  v_dep jsonb; v_rec jsonb; v_act jsonb; v_ok boolean; v_bank numeric; v_items jsonb; v_ids jsonb; v_gen numeric;
  v_month date := date_trunc('month', current_date)::date;
begin
  v_m := save_missionary('{"display_name":"Test Missionary Family","role_title":"Test"}');
  v_f := (v_m->>'fund_id')::uuid;
  v_d := (save_donor('{"donor_type":"individual","first_name":"Test","last_name":"Donor"}')->>'id')::uuid;
  v_gen := _fund_balance('f0000000-0000-0000-0000-000000000001');

  -- 1. fee: 10% capped at 250 / month in date order
  g1 := post_gift(jsonb_build_object('donor_id', v_d, 'gift_date', v_month + 1, 'method','check',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'amount', 1000))));
  g2 := post_gift(jsonb_build_object('donor_id', v_d, 'gift_date', v_month + 2, 'method','check',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'amount', 1000))));
  g3 := post_gift(jsonb_build_object('donor_id', v_d, 'gift_date', v_month + 3, 'method','check',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'amount', 1000))));
  select sum(admin_fee) into v from gift_lines where fund_id = v_f;
  assert v = 250, 'cap: expected 250 got ' || v;
  assert (select admin_fee from gift_lines where gift_id = (g3->>'id')::uuid) = 50, 'third gift fee should be 50';
  assert _fund_balance(v_f) = 2750, 'fund balance after fees ' || _fund_balance(v_f);
  assert _fund_balance('f0000000-0000-0000-0000-000000000001') = v_gen + 250, 'general got fees';

  -- 2. void the first gift: fees reallocate (100 + 100), general gives back 50
  perform void_gift(jsonb_build_object('id', g1->>'id', 'reason', 'test'));
  select sum(admin_fee) into v from gift_lines gl join gifts g on g.id = gl.gift_id where fund_id = v_f and g.status = 'posted';
  assert v = 200, 'after void expected 200 got ' || v;
  assert _fund_balance(v_f) = 1800, 'fund after void ' || _fund_balance(v_f);
  assert _fund_balance('f0000000-0000-0000-0000-000000000001') = v_gen + 200, 'general after void';

  -- 3. fee-exempt line + split gift + small gift
  g4 := post_gift(jsonb_build_object('donor_id', v_d, 'gift_date', v_month + 4, 'method','cash',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'amount', 20, 'fee_exempt', true),
                                   jsonb_build_object('fund_id', 'f0000000-0000-0000-0000-000000000001', 'amount', 15.55))));
  assert (select sum(admin_fee) from gift_lines where gift_id = (g4->>'id')::uuid) = 0, 'exempt';
  assert (g4->>'total_amount')::numeric = 35.55, 'split total';

  -- 4. totals tie out: funds = bank + undeposited, trial balance balances
  v_dash := get_dashboard('{}');
  assert (v_dash->>'total_funds')::numeric = (v_dash->>'bank_balance')::numeric + (v_dash->>'undeposited')::numeric, 'funds = bank + undeposited';
  assert (select sum(_fund_balance(id)) from funds) = (v_dash->>'total_funds')::numeric, 'sum of funds';
  v_tb := report_trial_balance('{}');
  assert v_tb->>'total_debit' = v_tb->>'total_credit', 'trial balance';

  -- 5. ledger is immutable
  v_ok := false;
  begin update journal_lines set debit = debit where true; exception when others then v_ok := true; end;
  assert v_ok, 'journal lines must be immutable';
  v_ok := false;
  begin delete from journal_entries where true; exception when others then v_ok := true; end;
  assert v_ok, 'journal entries must be undeletable';

  -- 6. unbalanced entry rejected
  v_ok := false;
  begin
    perform post_journal_entry(jsonb_build_object('entry_date', current_date, 'memo','bad', 'lines', jsonb_build_array(
      jsonb_build_object('account_id','a0000000-0000-0000-0000-000000001000','fund_id', v_f, 'debit', 10),
      jsonb_build_object('account_id','a0000000-0000-0000-0000-000000004900','fund_id', 'f0000000-0000-0000-0000-000000000001', 'credit', 10))));
    set constraints all immediate;
  exception when others then v_ok := true; end;
  assert v_ok, 'cross-fund unbalanced entry must be rejected';
  set constraints all deferred;

  -- 7. overdraft protection
  v_ok := false;
  begin
    perform post_disbursement(jsonb_build_object('disb_date', current_date, 'payee_name','X','method','check',
      'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'account_id','a0000000-0000-0000-0000-000000005000','amount', 999999))));
  exception when others then v_ok := sqlerrm like 'OVERDRAFT%'; end;
  assert v_ok, 'overdraft must be blocked';

  -- 8. deposit undeposited gifts, then reconcile
  select jsonb_agg(id) into v_ids from gifts where status = 'posted' and deposit_id is null and gift_date <= current_date;
  v_dep := post_deposit(jsonb_build_object('deposit_date', current_date, 'gift_ids', v_ids));
  assert (get_dashboard('{}')->>'undeposited')::numeric = 0, 'nothing undeposited';
  v_rec := get_reconciliation(jsonb_build_object('statement_date', current_date));
  select coalesce(sum((x->>'amount')::numeric),0) into v from jsonb_array_elements(v_rec->'items') x;
  v_bank := (v_rec->>'beginning_balance')::numeric + v;
  -- wrong balance must fail
  v_ok := false;
  begin
    perform save_reconciliation(jsonb_build_object('statement_date', current_date, 'statement_balance', v_bank + 1,
      'entry_ids', (select jsonb_agg(x->'entry_id') from jsonb_array_elements(v_rec->'items') x), 'complete', true));
  exception when others then v_ok := sqlerrm like 'Not balanced%'; end;
  assert v_ok, 'reconciliation must not complete when out of balance';
  perform save_reconciliation(jsonb_build_object('statement_date', current_date, 'statement_balance', v_bank,
      'entry_ids', (select jsonb_agg(x->'entry_id') from jsonb_array_elements(v_rec->'items') x), 'complete', true));
  assert (v_bank = (get_dashboard('{}')->>'bank_balance')::numeric), 'reconciled = book (all cleared) ' || v_bank;
  assert jsonb_array_length(get_reconciliation(jsonb_build_object('statement_date', current_date))->'items') = 0, 'all cleared';

  -- 9. cleared deposit cannot be voided
  v_ok := false;
  begin perform void_deposit(jsonb_build_object('id', v_dep->>'id', 'reason','x')); exception when others then v_ok := true; end;
  assert v_ok, 'cleared deposit void blocked';

  -- 10. void a deposited gift = returned check: hits Checking, shows on next reconciliation
  perform void_gift(jsonb_build_object('id', g2->>'id', 'reason', 'returned NSF'));
  v_rec := get_reconciliation(jsonb_build_object('statement_date', current_date));
  assert jsonb_array_length(v_rec->'items') >= 1, 'returned check appears';
  assert exists (select 1 from jsonb_array_elements(v_rec->'items') x where (x->>'amount')::numeric = -1000), 'returned check -1000';
  v_dash := get_dashboard('{}');
  assert (v_dash->>'total_funds')::numeric = (v_dash->>'bank_balance')::numeric + (v_dash->>'undeposited')::numeric, 'tie-out after NSF';

  -- 11. statement of activities ties to fund balances
  v_act := report_activities(jsonb_build_object('from', '2000-01-01', 'to', current_date));
  assert (v_act->>'beginning_without')::numeric + (v_act->>'change_without')::numeric = (v_act->>'ending_without')::numeric, 'activities without';
  assert (v_act->>'revenue_without')::numeric + (v_act->>'released')::numeric - (v_act->>'total_expenses')::numeric
         + (v_act->'opening_entries'->>'without')::numeric = (v_act->>'change_without')::numeric,
         'without column: rev + released - expenses + opening = change (' || (v_act->>'change_without') || ')';
  assert (v_act->>'revenue_with')::numeric - (v_act->>'released')::numeric + (v_act->'opening_entries'->>'with')::numeric
         = (v_act->>'change_with')::numeric, 'with column';
  assert (v_act->>'ending_without')::numeric + (v_act->>'ending_with')::numeric = (get_dashboard('{}')->>'total_funds')::numeric, 'ending = total funds';

  -- 12. period close blocks back-dated posting; void in closed month reverses in first open day
  perform set_closed_through(jsonb_build_object('closed_through', current_date - 1));
  v_ok := false;
  begin
    perform post_gift(jsonb_build_object('donor_id', v_d, 'gift_date', current_date - 5, 'method','check',
      'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'amount', 10))));
  exception when others then v_ok := sqlerrm like 'The books are closed%'; end;
  assert v_ok, 'closed period must block';
  perform set_closed_through('{"closed_through":null}');

  -- 13. donor statement
  assert (report_donor_statements(jsonb_build_object('year', extract(year from current_date), 'donor_id', v_d))
           ->'statements'->0->>'total')::numeric = 35.55 + 1000, 'donor statement total';

  -- 14. missionary account page
  v_act := get_fund_account(jsonb_build_object('fund_id', v_f, 'from', v_month, 'to', current_date));
  assert (v_act->>'opening_balance')::numeric
         + (select sum((r->>'amount')::numeric) from jsonb_array_elements(v_act->'rows') r) = (v_act->>'closing_balance')::numeric, 'fund statement rolls';

  -- 15. export works
  assert jsonb_typeof(export_all_data('{}')->'journal_lines') = 'array', 'export';
  -- 16. payees & 1099: a payment to a missionary links their payee and counts in box 1
  perform post_disbursement(jsonb_build_object('disb_date', current_date, 'payee_name', 'ignored', 'missionary_id', v_m->>'id',
    'method', 'ach', 'allow_overdraft', true,
    'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 2500),
                               jsonb_build_object('fund_id', v_f, 'account_id', 'a0000000-0000-0000-0000-000000005100', 'amount', 100))));
  assert (select (r->>'nec1')::numeric from jsonb_array_elements(report_1099(jsonb_build_object('year', extract(year from current_date)))->'recipients') r
           where r->>'display_name' = 'Test Missionary Family') = 2500, '1099 box 1 excludes reimbursements';
  -- debit card payments are excluded (1099-K)
  perform post_disbursement(jsonb_build_object('disb_date', current_date, 'payee_name', 'x', 'missionary_id', v_m->>'id',
    'method', 'debit_card', 'allow_overdraft', true,
    'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 50))));
  assert (select (r->>'nec1')::numeric from jsonb_array_elements(report_1099(jsonb_build_object('year', extract(year from current_date)))->'recipients') r
           where r->>'display_name' = 'Test Missionary Family') = 2500, 'card payments excluded';
  assert _1099_threshold(2025) = 600 and _1099_threshold(2026) = 2000, 'thresholds';

  -- 17. donor import: dry run writes nothing; skip vs update
  assert (import_donors('{"dry_run":true,"rows":[{"first_name":"Zed","last_name":"Imported"}]}')->>'created')::int = 1, 'dry run counts';
  assert not exists (select 1 from donors where last_name = 'Imported'), 'dry run wrote nothing';
  perform import_donors('{"rows":[{"first_name":"Zed","last_name":"Imported","postal_code":"46526"}]}');
  assert (import_donors('{"rows":[{"first_name":"Zed","last_name":"Imported","postal_code":"46526","phone":"1"}]}')->>'skipped')::int = 1, 'skip existing';
  perform import_donors('{"mode":"update","rows":[{"first_name":"Zed","last_name":"Imported","postal_code":"46526","phone":"555"}]}');
  assert (select phone from donors where last_name = 'Imported') = '555', 'update existing';

  -- 18. recurring payments: post once per month, never twice; voiding allows re-posting
  declare v_rp jsonb; v_res jsonb; v_per text := to_char(current_date, 'YYYY-MM');
  begin
    v_rp := save_recurring(jsonb_build_object('payee_name', 'Test Missionary Family', 'missionary_id', v_m->>'id', 'day_of_month', 1,
      'start_month', v_per, 'lines', jsonb_build_array(jsonb_build_object('fund_id', v_f, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 10))));
    assert exists (select 1 from jsonb_array_elements(recurring_due(jsonb_build_object('period', v_per))->'items') x
                   where x->>'id' = v_rp->>'id' and not (x->>'posted')::boolean), 'due before posting';
    v_res := post_recurring(jsonb_build_object('period', v_per, 'allow_overdraft', true, 'items', jsonb_build_array(jsonb_build_object('id', v_rp->>'id'))));
    assert (v_res->>'posted')::int = 1, 'posted once: ' || v_res::text;
    v_res := post_recurring(jsonb_build_object('period', v_per, 'allow_overdraft', true, 'items', jsonb_build_array(jsonb_build_object('id', v_rp->>'id'))));
    assert (v_res->>'posted')::int = 0, 'second post refused';
    perform void_disbursement(jsonb_build_object('id', (select disbursement_id from recurring_runs where recurring_id = (v_rp->>'id')::uuid), 'reason', 't'));
    v_res := post_recurring(jsonb_build_object('period', v_per, 'allow_overdraft', true, 'items', jsonb_build_array(jsonb_build_object('id', v_rp->>'id'))));
    assert (v_res->>'posted')::int = 1, 'repost after void';
  end;

  -- 19. tax treatment chosen per line overrides the account default
  declare v_m2 jsonb; v_f2 uuid;
  begin
    v_m2 := save_missionary('{"display_name":"Tax Treatment Test"}'); v_f2 := (v_m2->>'fund_id')::uuid;
    perform post_disbursement(jsonb_build_object('disb_date', current_date, 'payee_name', 'x', 'missionary_id', v_m2->>'id', 'method', 'ach', 'allow_overdraft', true,
      'lines', jsonb_build_array(
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 1000),                                  -- default taxable
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005100', 'amount', 200),                                   -- default reimbursement
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 50, 'tax_treatment', 'reimbursement'),
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005100', 'amount', 30, 'tax_treatment', 'taxable'),
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005030', 'amount', 400),                                   -- extra funds: taxable
        jsonb_build_object('fund_id', v_f2, 'account_id', 'a0000000-0000-0000-0000-000000005010', 'amount', 300))));                                -- housing
    assert (select (r->>'nec1')::numeric from jsonb_array_elements(report_1099(jsonb_build_object('year', extract(year from current_date)))->'recipients') r
             where r->>'display_name' = 'Tax Treatment Test') = 1430, 'taxable = 1000 + 30 + 400';
    assert (select (r->>'reimbursed')::numeric from jsonb_array_elements(report_1099(jsonb_build_object('year', extract(year from current_date)))->'recipients') r
             where r->>'display_name' = 'Tax Treatment Test') = 250, 'reimbursed = 200 + 50';
    assert (select (r->>'housing')::numeric from jsonb_array_elements(report_1099(jsonb_build_object('year', extract(year from current_date)))->'recipients') r
             where r->>'display_name' = 'Tax Treatment Test') = 300, 'housing';
  end;

  raise notice 'ALL ACCOUNTING TESTS PASSED';
end $$;
rollback;
