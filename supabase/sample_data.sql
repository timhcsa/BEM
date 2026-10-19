-- =====================================================================
-- BEM Ledger — SAMPLE DATA for trying the app. Not a migration.
-- Uses BEM's real missionaries (already in the database); donors and
-- amounts are made up. Do not load this into production.
-- Dates are relative to today so the dashboard always looks current.
-- =====================================================================
do $$
declare
  m_hewitt uuid; m_rogers uuid; m_phewitt uuid; m_keller uuid; m_demorell uuid; m_sutherland uuid;
  f_hewitt uuid; f_rogers uuid; f_phewitt uuid; f_keller uuid; f_demorell uuid; f_sutherland uuid;
  f_gen uuid := 'f0000000-0000-0000-0000-000000000001'; f_conf uuid := 'f0000000-0000-0000-0000-000000000002';
  f_triage uuid;
  d uuid[]; g jsonb; v_start date := (date_trunc('month', current_date) - interval '3 months')::date;
  i int; mo int; v_date date; v_ids jsonb; r record;
begin
  if exists (select 1 from journal_entries) then
    raise exception 'Sample data can only be loaded into an empty ledger';
  end if;

  -- Missionaries come from the staff migration (20261019000600_bem_staff.sql)
  select m.id into m_hewitt from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-HEWITT';
  select m.id into m_rogers from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-ROGERS';
  select m.id into m_phewitt from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-PHEWITT';
  select m.id into m_keller from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-KELLER';
  select m.id into m_demorell from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-DEMORELL';
  select m.id into m_sutherland from missionaries m join funds f on f.id = m.fund_id where f.code = 'M-SUTHERLAND';
  if m_hewitt is null or m_sutherland is null then
    raise exception 'The BEM staff missionaries are missing; run the migrations first';
  end if;
  select fund_id into f_hewitt from missionaries where id = m_hewitt;
  select fund_id into f_rogers from missionaries where id = m_rogers;
  select fund_id into f_phewitt from missionaries where id = m_phewitt;
  select fund_id into f_keller from missionaries where id = m_keller;
  select fund_id into f_demorell from missionaries where id = m_demorell;
  select fund_id into f_sutherland from missionaries where id = m_sutherland;
  select id into f_triage from funds where code = 'TRIAGE';
  if f_triage is null then
  select (save_fund(jsonb_build_object('code','TRIAGE','name','The Triage Fund','kind','other','restriction','with','sort',3,
          'description','Pastor Network Initiative - help for churches in need'))->>'id')::uuid into f_triage;
  end if;

  -- Donors
  d := array[
    (save_donor('{"donor_type":"household","first_name":"Robert","spouse_name":"Linda","last_name":"Anderson","email":"randerson@example.com","phone":"574-555-0101","address_line1":"112 Maple St","city":"Goshen","state":"IN","postal_code":"46526","church_affiliation":"First Baptist Goshen"}')->>'id')::uuid,
    (save_donor('{"donor_type":"church","organization_name":"Grace Baptist Church","contact_name":"Pastor Mark Ellis","email":"office@gracekokomo.example","address_line1":"400 Main St","city":"Kokomo","state":"IN","postal_code":"46901"}')->>'id')::uuid,
    (save_donor('{"donor_type":"individual","first_name":"Margaret","last_name":"Collins","email":"mcollins@example.com","address_line1":"9 Elm Ct","city":"Elkhart","state":"IN","postal_code":"46514","receipt_preference":"mail"}')->>'id')::uuid,
    (save_donor('{"donor_type":"church","organization_name":"Milan Baptist Church","address_line1":"1 Church Rd","city":"Milan","state":"MI","postal_code":"48160"}')->>'id')::uuid,
    (save_donor('{"donor_type":"household","first_name":"David","spouse_name":"Ruth","last_name":"Miller","email":"dmiller@example.com","address_line1":"55 County Rd 20","city":"Middlebury","state":"IN","postal_code":"46540"}')->>'id')::uuid,
    (save_donor('{"donor_type":"church","organization_name":"Fellowship Baptist Church","address_line1":"300 Center St","city":"Marshalltown","state":"IA","postal_code":"50158"}')->>'id')::uuid,
    (save_donor('{"donor_type":"household","first_name":"James","spouse_name":"Karen","last_name":"Thompson","email":"jkthompson@example.com","address_line1":"782 Oak Ave","city":"Orem","state":"UT","postal_code":"84057"}')->>'id')::uuid,
    (save_donor('{"donor_type":"individual","first_name":"Helen","last_name":"Wright","address_line1":"14 Pine St","city":"Nephi","state":"UT","postal_code":"84648","receipt_preference":"mail"}')->>'id')::uuid,
    (save_donor('{"donor_type":"foundation","organization_name":"Heartland Christian Foundation","email":"grants@heartland.example","address_line1":"PO Box 77","city":"Fort Wayne","state":"IN","postal_code":"46802"}')->>'id')::uuid,
    (save_donor('{"donor_type":"household","first_name":"Paul","spouse_name":"Esther","last_name":"Yoder","address_line1":"610 State Rd 4","city":"Goshen","state":"IN","postal_code":"46528"}')->>'id')::uuid
  ];

  -- Opening balances on the first day of the sample period
  perform post_opening_balances(jsonb_build_object('entry_date', v_start - 1, 'memo', 'Opening balances (from QuickBooks)',
    'balances', jsonb_build_array(
      jsonb_build_object('fund_id', f_gen, 'amount', 8450.00),
      jsonb_build_object('fund_id', f_conf, 'amount', 2300.00),
      jsonb_build_object('fund_id', f_triage, 'amount', 1500.00),
      jsonb_build_object('fund_id', f_hewitt, 'amount', 3120.55),
      jsonb_build_object('fund_id', f_rogers, 'amount', 1875.00),
      jsonb_build_object('fund_id', f_phewitt, 'amount', 940.00),
      jsonb_build_object('fund_id', f_keller, 'amount', 2210.40),
      jsonb_build_object('fund_id', f_demorell, 'amount', 1650.00),
      jsonb_build_object('fund_id', f_sutherland, 'amount', 2780.25))));

  -- Three full months + this month of giving, deposits and support payments
  for mo in 0..3 loop
    v_date := (v_start + (mo || ' months')::interval)::date;
    exit when v_date > current_date;
    perform post_gift(jsonb_build_object('donor_id', d[1], 'gift_date', v_date + 2, 'method','check','reference', (1040+mo)::text,
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_hewitt, 'amount', 200), jsonb_build_object('fund_id', f_gen, 'amount', 50))));
    perform post_gift(jsonb_build_object('donor_id', d[2], 'gift_date', v_date + 3, 'method','check','reference', (8812+mo)::text,
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_hewitt, 'amount', 1500), jsonb_build_object('fund_id', f_sutherland, 'amount', 500))));
    perform post_gift(jsonb_build_object('donor_id', d[3], 'gift_date', v_date + 4, 'method','check','reference', (311+mo)::text,
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_rogers, 'amount', 100))));
    perform post_gift(jsonb_build_object('donor_id', d[4], 'gift_date', v_date + 5, 'method','ach',
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_hewitt, 'amount', 1250))));
    perform post_gift(jsonb_build_object('donor_id', d[5], 'gift_date', v_date + 6, 'method','online','reference','ZF-' || (5500+mo),
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_keller, 'amount', 300), jsonb_build_object('fund_id', f_conf, 'amount', 100))));
    perform post_gift(jsonb_build_object('donor_id', d[6], 'gift_date', v_date + 8, 'method','check','reference', (2201+mo)::text,
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_sutherland, 'amount', 750))));
    perform post_gift(jsonb_build_object('donor_id', d[7], 'gift_date', v_date + 9, 'method','online','reference','ZF-' || (5600+mo),
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_demorell, 'amount', 400))));
    perform post_gift(jsonb_build_object('donor_id', d[8], 'gift_date', v_date + 10, 'method','cash',
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_gen, 'amount', 40))));
    perform post_gift(jsonb_build_object('donor_id', d[10], 'gift_date', v_date + 11, 'method','check','reference', (77+mo)::text,
      'lines', jsonb_build_array(jsonb_build_object('fund_id', f_phewitt, 'amount', 150), jsonb_build_object('fund_id', f_rogers, 'amount', 150))));
    if mo = 1 then
      perform post_gift(jsonb_build_object('donor_id', d[9], 'gift_date', v_date + 12, 'method','check','reference','10455',
        'memo','Grant for pastor assistance',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', f_triage, 'amount', 5000))));
    end if;

    -- deposit everything received so far this month, on the 15th (or today)
    -- (this month: only the first few gifts, so some are left to deposit)
    if least(v_date + case when v_date = date_trunc('month', current_date)::date then 5 else 14 end, current_date) >= v_date + 2 then
      select jsonb_agg(id) into v_ids from gifts where deposit_id is null and status = 'posted'
         and gift_date <= least(v_date + case when v_date = date_trunc('month', current_date)::date then 5 else 14 end, current_date);
      if v_ids is not null then
        perform post_deposit(jsonb_build_object('deposit_date', least(v_date + case when v_date = date_trunc('month', current_date)::date then 5 else 14 end, current_date), 'gift_ids', v_ids));
      end if;
    end if;

    -- support payments on the 25th of completed months
    if v_date + 24 <= current_date then
      for r in select m.display_name, m.fund_id, m.id from missionaries m loop
        if _fund_balance(r.fund_id) > 600 then
          perform post_disbursement(jsonb_build_object('disb_date', v_date + 24, 'payee_name', r.display_name, 'missionary_id', r.id,
            'method','ach', 'memo','Monthly support',
            'lines', jsonb_build_array(jsonb_build_object('fund_id', r.fund_id, 'account_id', 'a0000000-0000-0000-0000-000000005000',
                                       'amount', round((_fund_balance(r.fund_id) * 0.6)::numeric, -1)))));
        end if;
      end loop;
      perform post_disbursement(jsonb_build_object('disb_date', v_date + 20, 'payee_name','Intuit / office software','method','debit_card',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', f_gen, 'account_id', 'a0000000-0000-0000-0000-000000006040', 'amount', 45.00))));
      perform post_disbursement(jsonb_build_object('disb_date', v_date + 27, 'payee_name','Lake City Bank','method','bank_fee',
        'lines', jsonb_build_array(jsonb_build_object('fund_id', f_gen, 'account_id', 'a0000000-0000-0000-0000-000000006010', 'amount', 12.00))));
    end if;
  end loop;

  -- A reimbursement and a conference expense
  perform post_disbursement(jsonb_build_object('disb_date', v_start + 40, 'payee_name','Ted & Marlene Sutherland','missionary_id', m_sutherland,
    'method','check','reference','2051','memo','Travel reimbursement - Iowa churches',
    'lines', jsonb_build_array(jsonb_build_object('fund_id', f_sutherland, 'account_id', 'a0000000-0000-0000-0000-000000005150', 'amount', 386.40))));
  perform post_disbursement(jsonb_build_object('disb_date', v_start + 55, 'payee_name','Kokomo Printing Co.','method','check','reference','2052',
    'memo','Conference brochures',
    'lines', jsonb_build_array(jsonb_build_object('fund_id', f_conf, 'account_id', 'a0000000-0000-0000-0000-000000005200', 'amount', 275.00))));

  -- Sample W-9 information (made-up numbers) and a non-cash gift
  update payees set legal_name = 'Ted Sutherland', tin_type = 'ssn', tin = '123456789', w9_on_file = true,
         address_line1 = '210 Prairie Ln', city = 'Union', state = 'IA', postal_code = '50258'
   where missionary_id = m_sutherland;
  update payees set legal_name = 'Timothy Hewitt', tin_type = 'ssn', tin = '987654321', w9_on_file = true,
         address_line1 = 'P.O. Box 4', city = 'Goshen', state = 'IN', postal_code = '46527'
   where missionary_id = m_hewitt;
  perform post_gift(jsonb_build_object('donor_id', d[5], 'gift_date', v_start + 50, 'method', 'stock', 'reference', 'Edward Jones',
    'memo', '20 shares of Example Corp. common stock',
    'lines', jsonb_build_array(jsonb_build_object('fund_id', f_gen, 'amount', 1200))));

  -- Monthly support set up as recurring payments (due on the 25th)
  perform save_recurring(jsonb_build_object('name', 'Tim & Sandy Hewitt - monthly support', 'payee_name', 'Tim & Sandy Hewitt',
    'missionary_id', m_hewitt, 'method', 'ach', 'day_of_month', 25, 'start_month', to_char(current_date, 'YYYY-MM'),
    'lines', jsonb_build_array(
      jsonb_build_object('fund_id', f_hewitt, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 1800),
      jsonb_build_object('fund_id', f_hewitt, 'account_id', 'a0000000-0000-0000-0000-000000005010', 'amount', 700))));
  perform save_recurring(jsonb_build_object('name', 'Ted & Marlene Sutherland - monthly support', 'payee_name', 'Ted & Marlene Sutherland',
    'missionary_id', m_sutherland, 'method', 'ach', 'day_of_month', 25, 'start_month', to_char(current_date, 'YYYY-MM'),
    'lines', jsonb_build_array(
      jsonb_build_object('fund_id', f_sutherland, 'account_id', 'a0000000-0000-0000-0000-000000005000', 'amount', 900),
      jsonb_build_object('fund_id', f_sutherland, 'account_id', 'a0000000-0000-0000-0000-000000005010', 'amount', 300))));
  perform save_recurring(jsonb_build_object('name', 'Office software subscription', 'payee_name', 'Intuit / office software',
    'method', 'debit_card', 'day_of_month', 20, 'start_month', to_char(current_date, 'YYYY-MM'),
    'lines', jsonb_build_array(jsonb_build_object('fund_id', f_gen, 'account_id', 'a0000000-0000-0000-0000-000000006040', 'amount', 45))));

  update settings set ein = '00-0000000', receipt_signer = 'Treasurer, Barnabas Enrichment Ministries' where id = 1;
end $$;
