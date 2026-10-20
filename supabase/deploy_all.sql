-- >>> 20261019000100_schema.sql
-- =====================================================================
-- BEM Ledger — core schema
-- Plain PostgreSQL. Runs unchanged on Supabase and on the local
-- in-browser database (PGlite). Safe to run more than once.
--
-- Accounting model
--   * Double-entry: every financial event becomes a journal entry whose
--     debits equal its credits.
--   * Fund accounting: every journal line carries a fund, and every entry
--     balances within each fund, so each fund is a self-balancing set of
--     books. A fund's balance = its share of the pooled bank account.
--   * Net assets (ASC 958): each fund is classified "without" or "with"
--     donor restrictions; reports roll funds up by that class.
--   * Audit trail: posted journal lines can never be edited or deleted.
--     Corrections are made by voiding (a reversing entry) and re-entering.
--   * Period close: nothing can be posted on or before settings.closed_through.
-- =====================================================================

-- Who is making the change. Locally this is "local-admin"; the Supabase
-- security migration replaces it with the signed-in user's email.
create or replace function current_actor() returns text
language sql stable as $$ select 'local-admin'::text $$;

-- ---------------------------------------------------------------------
-- Organization settings (single row)
-- ---------------------------------------------------------------------
create table if not exists settings (
  id                      int primary key default 1 check (id = 1),
  org_name                text not null default 'Barnabas Enrichment Ministries',
  ein                     text,
  address                 text default 'P.O. Box 4, Goshen, IN 46527',
  phone                   text default '765-667-2532',
  website                 text default 'barnabasenrichmentministries.org',
  logo_url                text,
  fiscal_year_start_month int  not null default 1 check (fiscal_year_start_month between 1 and 12),
  closed_through          date,
  admin_fee_fund_id       uuid,
  default_admin_fee_rate  numeric(6,4)  not null default 0.10,
  default_admin_fee_cap   numeric(12,2) not null default 250.00,
  receipt_signer          text,
  receipt_note            text default 'No goods or services were provided in exchange for these contributions other than intangible religious benefits.',
  updated_at              timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Chart of accounts
-- ---------------------------------------------------------------------
create table if not exists accounts (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  name             text not null,
  type             text not null check (type in ('asset','liability','net_assets','revenue','expense')),
  -- bank: a real bank account (reconciled); undeposited: gifts received not yet
  -- deposited; interfund: internal movement between funds (nets to zero
  -- organization-wide); opening: opening net assets.
  subtype          text check (subtype in ('bank','undeposited','interfund_fee','interfund_transfer',
                                           'opening_without','opening_with',
                                           'contribution_individual','contribution_organization',
                                           'program_revenue','other_revenue','expense','other')),
  functional_class text check (functional_class in ('program','management_general','fundraising')),
  description      text,
  is_system        boolean not null default false,
  active           boolean not null default true,
  sort             int not null default 0,
  created_at       timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Funds (general, conference, each missionary, other designated funds)
-- ---------------------------------------------------------------------
create table if not exists funds (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  name             text not null,
  kind             text not null check (kind in ('general','conference','missionary','other')),
  restriction      text not null check (restriction in ('without','with')),
  admin_fee_applies boolean not null default false,
  admin_fee_rate   numeric(6,4),          -- null = use settings default
  admin_fee_cap    numeric(12,2),         -- null = use settings default (per calendar month)
  description      text,
  is_system        boolean not null default false,
  active           boolean not null default true,
  sort             int not null default 0,
  created_at       timestamptz not null default now()
);

create table if not exists missionaries (
  id            uuid primary key default gen_random_uuid(),
  fund_id       uuid not null unique references funds(id),
  display_name  text not null,          -- "Ted & Marlene Sutherland"
  role_title    text,
  photo_url     text,                   -- URL or small data: URL (resized on upload)
  email         text,
  phone         text,
  address       text,
  start_date    date,
  bio           text,
  active        boolean not null default true,
  sort          int not null default 0,
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Donors
-- ---------------------------------------------------------------------
create table if not exists donors (
  id                 uuid primary key default gen_random_uuid(),
  donor_number       bigint generated by default as identity unique,
  donor_type         text not null default 'individual'
                     check (donor_type in ('individual','household','church','organization','foundation','business')),
  first_name         text,
  last_name          text,
  spouse_name        text,
  organization_name  text,
  display_name       text not null,     -- maintained by trigger
  sort_name          text not null,     -- maintained by trigger
  salutation         text,              -- "Dear Bob and Mary"
  email              text,
  phone              text,
  address_line1      text,
  address_line2      text,
  city               text,
  state              text,
  postal_code        text,
  country            text default 'US',
  church_affiliation text,
  contact_name       text,              -- for churches / organizations
  receipt_preference text not null default 'email' check (receipt_preference in ('email','mail','none')),
  is_anonymous       boolean not null default false,
  notes              text,
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists donors_sort_name_idx on donors (sort_name);

create or replace function donors_set_names() returns trigger language plpgsql as $$
begin
  if new.donor_type in ('individual','household') then
    new.display_name := trim(concat_ws(' ',
      nullif(trim(coalesce(new.first_name,'') ||
        case when coalesce(new.spouse_name,'') <> '' then ' & ' || new.spouse_name else '' end), ''),
      new.last_name));
    new.sort_name := lower(trim(concat_ws(', ', nullif(new.last_name,''), nullif(new.first_name,''))));
  else
    new.display_name := coalesce(nullif(trim(new.organization_name),''), 'Unnamed organization');
    new.sort_name := lower(new.display_name);
  end if;
  if coalesce(new.display_name,'') = '' then
    raise exception 'Donor needs a name';
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists donors_set_names_trg on donors;
create trigger donors_set_names_trg before insert or update on donors
  for each row execute function donors_set_names();

-- ---------------------------------------------------------------------
-- General ledger
-- ---------------------------------------------------------------------
create table if not exists journal_entries (
  id                uuid primary key default gen_random_uuid(),
  entry_number      bigint generated by default as identity unique,
  entry_date        date not null,
  memo              text,
  source_type       text not null check (source_type in
                    ('gift','admin_fee','deposit','disbursement','transfer','opening','adjustment','reversal')),
  source_id         uuid,
  reverses_entry_id uuid references journal_entries(id),
  created_at        timestamptz not null default now(),
  created_by        text not null default current_actor()
);
create index if not exists je_date_idx on journal_entries (entry_date);
create index if not exists je_source_idx on journal_entries (source_type, source_id);

create table if not exists journal_lines (
  id               uuid primary key default gen_random_uuid(),
  entry_id         uuid not null references journal_entries(id),
  account_id       uuid not null references accounts(id),
  fund_id          uuid not null references funds(id),
  debit            numeric(14,2) not null default 0,
  credit           numeric(14,2) not null default 0,
  functional_class text check (functional_class in ('program','management_general','fundraising')),
  memo             text,
  constraint jl_amounts_chk check (debit >= 0 and credit >= 0 and (debit = 0 or credit = 0) and (debit + credit) > 0)
);
create index if not exists jl_entry_idx on journal_lines (entry_id);
create index if not exists jl_account_idx on journal_lines (account_id);
create index if not exists jl_fund_idx on journal_lines (fund_id);

-- Every entry must balance in total AND within each fund.
create or replace function je_check_balanced() returns trigger language plpgsql as $$
declare v_entry uuid; v_bad record;
begin
  v_entry := coalesce(new.entry_id, old.entry_id);
  select fund_id, sum(debit) d, sum(credit) c into v_bad
    from journal_lines where entry_id = v_entry
    group by fund_id having sum(debit) <> sum(credit) limit 1;
  if found then
    raise exception 'Journal entry does not balance within fund (debits % / credits %)', v_bad.d, v_bad.c;
  end if;
  return null;
end $$;
drop trigger if exists jl_balanced_trg on journal_lines;
create constraint trigger jl_balanced_trg after insert on journal_lines
  deferrable initially deferred for each row execute function je_check_balanced();

-- Posted ledger is permanent.
create or replace function ledger_immutable() returns trigger language plpgsql as $$
begin
  raise exception 'Posted ledger records cannot be changed or deleted. Void the transaction instead.';
end $$;
drop trigger if exists je_immutable_trg on journal_entries;
create trigger je_immutable_trg before update or delete on journal_entries
  for each row execute function ledger_immutable();
drop trigger if exists jl_immutable_trg on journal_lines;
create trigger jl_immutable_trg before update or delete on journal_lines
  for each row execute function ledger_immutable();

-- Closed periods are locked.
create or replace function je_check_period() returns trigger language plpgsql as $$
declare v_closed date;
begin
  select closed_through into v_closed from settings where id = 1;
  if v_closed is not null and new.entry_date <= v_closed then
    raise exception 'The books are closed through %. Use a date after that.', to_char(v_closed, 'Mon DD, YYYY');
  end if;
  return new;
end $$;
drop trigger if exists je_period_trg on journal_entries;
create trigger je_period_trg before insert on journal_entries
  for each row execute function je_check_period();

-- ---------------------------------------------------------------------
-- Gifts (contributions). One gift = one check/payment, split across funds.
-- ---------------------------------------------------------------------
create table if not exists deposits (
  id               uuid primary key default gen_random_uuid(),
  deposit_number   bigint generated by default as identity unique,
  deposit_date     date not null,
  bank_account_id  uuid not null references accounts(id),
  total            numeric(14,2) not null,
  memo             text,
  status           text not null default 'posted' check (status in ('posted','void')),
  void_reason      text,
  voided_at        timestamptz,
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor()
);

create table if not exists gifts (
  id               uuid primary key default gen_random_uuid(),
  gift_number      bigint generated by default as identity unique,
  donor_id         uuid references donors(id),          -- null = anonymous / loose cash
  gift_date        date not null,
  method           text not null check (method in ('check','cash','online','ach','card','stock','other')),
  reference        text,                                 -- check number, transaction id
  total_amount     numeric(14,2) not null check (total_amount > 0),
  memo             text,
  status           text not null default 'posted' check (status in ('posted','void')),
  void_reason      text,
  voided_at        timestamptz,
  deposit_id       uuid references deposits(id),
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor()
);
create index if not exists gifts_date_idx on gifts (gift_date);
create index if not exists gifts_donor_idx on gifts (donor_id);

create table if not exists gift_lines (
  id          uuid primary key default gen_random_uuid(),
  gift_id     uuid not null references gifts(id),
  fund_id     uuid not null references funds(id),
  amount      numeric(14,2) not null check (amount > 0),
  fee_exempt  boolean not null default false,
  admin_fee   numeric(14,2) not null default 0,  -- current fee charged (kept in step with the ledger)
  memo        text
);
create index if not exists gift_lines_fund_idx on gift_lines (fund_id);
create index if not exists gift_lines_gift_idx on gift_lines (gift_id);

-- ---------------------------------------------------------------------
-- Disbursements (checks, ACH and card payments out of the bank)
-- ---------------------------------------------------------------------
create table if not exists disbursements (
  id               uuid primary key default gen_random_uuid(),
  disb_number      bigint generated by default as identity unique,
  disb_date        date not null,
  payee_name       text not null,
  missionary_id    uuid references missionaries(id),
  method           text not null check (method in ('check','ach','debit_card','wire','bank_fee','other')),
  reference        text,
  bank_account_id  uuid not null references accounts(id),
  total            numeric(14,2) not null check (total > 0),
  memo             text,
  status           text not null default 'posted' check (status in ('posted','void')),
  void_reason      text,
  voided_at        timestamptz,
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor()
);

create table if not exists disbursement_lines (
  id               uuid primary key default gen_random_uuid(),
  disbursement_id  uuid not null references disbursements(id),
  fund_id          uuid not null references funds(id),
  account_id       uuid not null references accounts(id),
  functional_class text not null check (functional_class in ('program','management_general','fundraising')),
  amount           numeric(14,2) not null check (amount > 0),
  memo             text
);

-- ---------------------------------------------------------------------
-- Interfund transfers (manual). Admin fees are posted automatically.
-- ---------------------------------------------------------------------
create table if not exists transfers (
  id               uuid primary key default gen_random_uuid(),
  transfer_date    date not null,
  from_fund_id     uuid not null references funds(id),
  to_fund_id       uuid not null references funds(id),
  amount           numeric(14,2) not null check (amount > 0),
  reason           text not null,
  status           text not null default 'posted' check (status in ('posted','void')),
  void_reason      text,
  voided_at        timestamptz,
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor(),
  check (from_fund_id <> to_fund_id)
);

-- ---------------------------------------------------------------------
-- Bank reconciliation
-- ---------------------------------------------------------------------
create table if not exists reconciliations (
  id                 uuid primary key default gen_random_uuid(),
  account_id         uuid not null references accounts(id),
  statement_date     date not null,
  statement_balance  numeric(14,2) not null,
  beginning_balance  numeric(14,2) not null,
  status             text not null default 'in_progress' check (status in ('in_progress','completed')),
  completed_at       timestamptz,
  completed_by       text,
  created_at         timestamptz not null default now()
);
-- One row per journal entry that touched the bank (its net bank amount).
create table if not exists reconciliation_items (
  reconciliation_id uuid not null references reconciliations(id) on delete cascade,
  entry_id          uuid not null references journal_entries(id),
  amount            numeric(14,2) not null,
  primary key (reconciliation_id, entry_id)
);

-- ---------------------------------------------------------------------
-- Future: bank feed. Transactions imported from the bank (CSV, Plaid,
-- etc.) land here and are matched to journal entries. No screens use it
-- yet; it exists so a bank connection can be added without a redesign.
-- ---------------------------------------------------------------------
create table if not exists bank_transactions (
  id               uuid primary key default gen_random_uuid(),
  account_id       uuid not null references accounts(id),
  posted_date      date not null,
  amount           numeric(14,2) not null,       -- + money in, - money out
  description      text,
  external_id      text,                          -- id from the bank / aggregator
  source           text not null default 'manual', -- 'csv', 'plaid', ...
  matched_entry_id uuid references journal_entries(id),
  raw              jsonb,
  imported_at      timestamptz not null default now(),
  unique (account_id, source, external_id)
);

-- Simple change log for master data (donors, funds, missionaries, settings).
create table if not exists audit_log (
  id         bigint generated by default as identity primary key,
  at         timestamptz not null default now(),
  actor      text not null default current_actor(),
  action     text not null,
  object     text not null,
  object_id  uuid,
  detail     jsonb
);


-- >>> 20261019000150_bills_tables.sql
-- =====================================================================
-- BEM Ledger — tables that later function files refer to (payees, bills).
-- Created early so every function file can be (re)loaded in order.
-- Safe to re-run.
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
-- employee (W-2, e.g. missionaries), contractor (1099) or vendor (business; usually no 1099)
alter table payees add column if not exists worker_type text not null default 'vendor'
  check (worker_type in ('employee','contractor','vendor'));

create table if not exists bill_payments (
  id               uuid primary key default gen_random_uuid(),
  payment_number   bigint generated by default as identity unique,
  pay_date         date not null,
  payee_id         uuid references payees(id),
  payee_name       text not null,
  method           text not null check (method in ('check','ach','debit_card','wire','other')),
  reference        text,                         -- check number or EFT confirmation
  bank_account_id  uuid not null references accounts(id),
  total            numeric(14,2) not null check (total > 0),
  memo             text,
  status           text not null default 'posted' check (status in ('posted','void')),
  void_reason      text,
  voided_at        timestamptz,
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor()
);

create table if not exists bills (
  id               uuid primary key default gen_random_uuid(),
  bill_number      bigint generated by default as identity unique,
  kind             text not null default 'bill' check (kind in ('bill','expense_report')),
  payee_id         uuid references payees(id),
  payee_name       text not null,
  missionary_id    uuid references missionaries(id),
  bill_date        date not null,
  due_date         date,
  reference        text,                         -- vendor invoice # / report period
  memo             text,
  total            numeric(14,2) not null check (total > 0),
  status           text not null default 'open' check (status in ('open','paid','void')),
  payment_id       uuid references bill_payments(id),
  void_reason      text,
  voided_at        timestamptz,
  journal_entry_id uuid references journal_entries(id),
  created_at       timestamptz not null default now(),
  created_by       text not null default current_actor()
);
create index if not exists bills_status_idx on bills (status);

create table if not exists bill_lines (
  id               uuid primary key default gen_random_uuid(),
  bill_id          uuid not null references bills(id),
  fund_id          uuid not null references funds(id),
  account_id       uuid not null references accounts(id),
  functional_class text not null check (functional_class in ('program','management_general','fundraising')),
  tax_treatment    text check (tax_treatment in ('taxable','reimbursement','housing')),
  amount           numeric(14,2) not null check (amount > 0),
  quantity         numeric(12,2),                -- miles, when the category is per-mile
  rate             numeric(8,4),
  expense_date     date,
  memo             text,
  sort             int not null default 0
);

-- A fund's cash (its share of Checking + undeposited gifts) — what it can actually pay.
create or replace function _fund_cash(p_fund uuid) returns numeric
language sql stable as $$
  select coalesce(sum(jl.debit - jl.credit), 0)
    from journal_lines jl join accounts a on a.id = jl.account_id
   where jl.fund_id = p_fund and a.type = 'asset'
$$;

create or replace function _fund_unpaid(p_fund uuid) returns numeric
language sql stable as $$
  select coalesce(sum(bl.amount), 0) from bill_lines bl join bills b on b.id = bl.bill_id
   where bl.fund_id = p_fund and b.status = 'open'
$$;



-- >>> 20261019000200_reference_data.sql
-- =====================================================================
-- BEM Ledger — reference data: settings row, chart of accounts, core funds.
-- Uses fixed ids so it can be re-run safely and other scripts can refer
-- to these rows. Edit names freely in the app; codes are what matter.
-- =====================================================================

insert into settings (id) values (1) on conflict (id) do nothing;

insert into accounts (id, code, name, type, subtype, functional_class, is_system, sort, description) values
 ('a0000000-0000-0000-0000-000000001000','1000','Operating Checking','asset','bank',null,true,10,'The ministry''s main bank account. All funds share this account.'),
 ('a0000000-0000-0000-0000-000000001050','1050','Undeposited Gifts','asset','undeposited',null,true,20,'Gifts received but not yet deposited at the bank.'),
 ('a0000000-0000-0000-0000-000000003000','3000','Opening Net Assets - Without Donor Restrictions','net_assets','opening_without',null,true,300,'Used for opening balances only.'),
 ('a0000000-0000-0000-0000-000000003100','3100','Opening Net Assets - With Donor Restrictions','net_assets','opening_with',null,true,310,'Used for opening balances only.'),
 ('a0000000-0000-0000-0000-000000003910','3910','Interfund - Administrative Fees','net_assets','interfund_fee',null,true,391,'Automatic 10% fee moved from missionary funds to the General Fund. Nets to zero organization-wide.'),
 ('a0000000-0000-0000-0000-000000003920','3920','Interfund - Transfers','net_assets','interfund_transfer',null,true,392,'Manual transfers between funds. Nets to zero organization-wide.'),
 ('a0000000-0000-0000-0000-000000004000','4000','Contributions - Individuals','revenue','contribution_individual',null,true,400,null),
 ('a0000000-0000-0000-0000-000000004010','4010','Contributions - Churches & Organizations','revenue','contribution_organization',null,true,401,null),
 ('a0000000-0000-0000-0000-000000004100','4100','Program Service Revenue','revenue','program_revenue',null,false,410,'Fees received for ministry services.'),
 ('a0000000-0000-0000-0000-000000004500','4500','Interest Income','revenue','other_revenue',null,false,450,null),
 ('a0000000-0000-0000-0000-000000004900','4900','Other Income','revenue','other_revenue',null,false,490,null),
 ('a0000000-0000-0000-0000-000000005000','5000','Missionary Support - Salary','expense','expense','program',false,500,null),
 ('a0000000-0000-0000-0000-000000005010','5010','Missionary Support - Housing Allowance','expense','expense','program',false,501,'Ministers'' housing allowance, as designated by the board.'),
 ('a0000000-0000-0000-0000-000000005020','5020','Payroll Taxes & Benefits','expense','expense','program',false,502,null),
 ('a0000000-0000-0000-0000-000000005100','5100','Missionary Ministry Expenses','expense','expense','program',false,510,'Reimbursed ministry expenses (receipts on file).'),
 ('a0000000-0000-0000-0000-000000005150','5150','Ministry Travel','expense','expense','program',false,515,null),
 ('a0000000-0000-0000-0000-000000005200','5200','Conference Expenses','expense','expense','program',false,520,null),
 ('a0000000-0000-0000-0000-000000005300','5300','Church & Pastor Assistance','expense','expense','program',false,530,'Grants such as The Triage Fund.'),
 ('a0000000-0000-0000-0000-000000006000','6000','Office & Administrative','expense','expense','management_general',false,600,null),
 ('a0000000-0000-0000-0000-000000006010','6010','Bank & Payment Processing Fees','expense','expense','management_general',false,601,null),
 ('a0000000-0000-0000-0000-000000006020','6020','Accounting & Legal','expense','expense','management_general',false,602,null),
 ('a0000000-0000-0000-0000-000000006030','6030','Insurance','expense','expense','management_general',false,603,null),
 ('a0000000-0000-0000-0000-000000006040','6040','Technology & Software','expense','expense','management_general',false,604,null),
 ('a0000000-0000-0000-0000-000000006050','6050','Postage & Printing','expense','expense','management_general',false,605,null),
 ('a0000000-0000-0000-0000-000000006500','6500','Fundraising & Donor Communications','expense','expense','fundraising',false,650,null),
 ('a0000000-0000-0000-0000-000000006900','6900','Other Expenses','expense','expense','management_general',false,690,null)
on conflict (id) do nothing;

insert into funds (id, code, name, kind, restriction, admin_fee_applies, is_system, sort, description) values
 ('f0000000-0000-0000-0000-000000000001','GEN','General Fund','general','without',false,true,1,'Unrestricted operating fund. Receives missionary administrative fees.'),
 ('f0000000-0000-0000-0000-000000000002','CONF','Conference Fund','conference','with',false,true,2,'Gifts designated for the Small Church Enrichment Conferences.')
on conflict (id) do nothing;

update settings set admin_fee_fund_id = 'f0000000-0000-0000-0000-000000000001'
 where id = 1 and admin_fee_fund_id is null;


-- >>> 20261019000300_posting.sql
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


-- >>> 20261019000310_posting_more.sql
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


-- >>> 20261019000400_master_data.sql
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


-- >>> 20261019000500_reports.sql
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


-- >>> 20261019000600_bem_staff.sql
-- =====================================================================
-- BEM Ledger — BEM's staff missionaries (from barnabasenrichmentministries.org/staff)
-- Each gets a missionary account (fund) with the standard admin fee.
-- Photos are served by the app from /public/staff/.
-- Safe to re-run: existing missionaries (matched by fund code or name) are
-- left alone, except that a missing photo or bio is filled in.
-- =====================================================================
do $$
declare r record; v_id uuid;
begin
  for r in select * from (values
    ('Tim & Sandy Hewitt', 'Co-Founders', 'M-HEWITT', '/staff/tim-sandy-hewitt.jpg', 1, 'Tim received the call from God to full time vocational ministry as a working professional (Electrical Engineer) and young father. He graduated from Grace Theological Seminary in Winona Lake Indiana in 1995 and, shortly thereafter, accepted the position of Senior Pastor at a small Independent Baptist Church in Elkhart Indiana. Tim served at Calvary Baptist Church for 12 years, three of those years having been bi-vocational as Engineer and Pastor. Through firsthand experience, the Hewitt''s know both the challenges and rewards of working ''solo'' in the ministry of the small local church.'),
    ('John & Beabea Rogers', 'Field Director & Missionaries', 'M-ROGERS', '/staff/john-beabea-rogers.jpg', 2, 'In December of 2000 the Rogers family moved to Indiana where John became Pre-Field Director for Evangelical Baptist Missions (2000-2008) and Regional Coordinator for North America (2009-2011). In addition to working with missionary appointees in their pre-field process, he and Beabea spent time assisting Bible believing churches in their efforts to develop their people for missions as well as teaching how to both witness for Jesus Christ and live their faith before others.'),
    ('Philip & Katie Hewitt', 'Technical Advisor', 'M-PHEWITT', '/staff/philip-katie-hewitt.jpg', 3, 'Philip and Katie met as teenagers in their church''s youth group, dated for 2 years and were married in 2005. They have served faithfully in many areas of their local church since that time. They have four children, who Katie homeschools. She also actively serves in their homeschool co-op. Having trained in the field of IT, Philip has worked in that capacity for the past 14+ years.'),
    ('Jim & Jeanne Keller', 'Midwest Field Director', 'M-KELLER', '/staff/jim-jeanne-keller.jpg', 4, 'Jim and Jeanne Keller have been involved in ministry for over 40 years. Jim has served as a pastor in three churches including 30 years at Bethel Baptist Church in Topeka, Kansas. In his early years, Jim was the campus pastor for a Christian School in South Dakota. Jim has also served as an adjunct professor for a Bible college and teaches overseas in pastoral training.'),
    ('Chris & Rachel DeMorell', 'Western Field Director', 'M-DEMORELL', '/staff/chris-rachel-demorell.jpg', 5, 'Chris DeMorell grew up in northern New Jersey in a non-practicing Catholic household. He attended Ohio State University after high school and was immediately involved in the fraternity party scene. It was between his sophomore and junior years that God began to work in his heart. Having very little Bible understanding he began reading a Gideon NT.'),
    ('Ted & Marlene Sutherland', 'Missionaries', 'M-SUTHERLAND', '/staff/ted-marlene-sutherland.jpg', 6, 'Ted and Marlene first met in 1970 while attending a Christian high school. Both were blessed to be raised in strong, God-centered Christian homes. During his high school years, Ted sensed God''s call to ministry. The couple married in 1976, and Ted later graduated from MBBC in 1983.')
  ) as s(display_name, role_title, fund_code, photo_url, sort, bio)
  loop
    select m.id into v_id from missionaries m join funds f on f.id = m.fund_id
     where f.code = r.fund_code or lower(m.display_name) = lower(r.display_name)
     limit 1;
    if v_id is null then
      perform save_missionary(jsonb_build_object('display_name', r.display_name, 'role_title', r.role_title,
        'fund_code', r.fund_code, 'photo_url', r.photo_url, 'sort', r.sort, 'bio', r.bio));
    else
      update missionaries set
        photo_url = case when photo_url is null or photo_url like '%base44.com%' then r.photo_url else photo_url end,
        bio = coalesce(bio, r.bio),
        role_title = coalesce(role_title, r.role_title)
      where id = v_id;
    end if;
  end loop;
end $$;

-- The Triage Fund (Pastor Network Initiative), named on the BEM website.
insert into funds (code, name, kind, restriction, admin_fee_applies, sort, description)
values ('TRIAGE', 'The Triage Fund', 'other', 'with', false, 3, 'Pastor Network Initiative - help for churches in need')
on conflict (code) do nothing;


-- >>> 20261019000700_tax_reporting.sql
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
-- employee (W-2, e.g. missionaries), contractor (1099) or vendor (business; usually no 1099)
alter table payees add column if not exists worker_type text not null default 'vendor'
  check (worker_type in ('employee','contractor','vendor'));
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
    update payees set missionary_id = p_missionary, worker_type = 'employee', is_1099 = false where id = v;
    return v;
  end if;
  -- BEM treats missionaries as employees (W-2), not 1099 contractors
  insert into payees(display_name, missionary_id, is_1099, worker_type) values (v_name, p_missionary, false, 'employee') returning id into v;
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
    worker_type = coalesce(nullif(p->>'worker_type',''), worker_type),
    is_1099 = case when coalesce(nullif(p->>'worker_type',''), worker_type) = 'employee' then false
                   else coalesce((p->>'is_1099')::boolean, false) end,
    w9_on_file = coalesce((p->>'w9_on_file')::boolean, false),
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
    update accounts set reimbursable = coalesce((p->>'reimbursable')::boolean, false), per_mile = coalesce((p->>'per_mile')::boolean, false)
     where id = v_id and type = 'expense';
  else
    update accounts set code = case when is_system then code else trim(p->>'code') end, name = trim(p->>'name'),
      functional_class = case when type = 'expense' then coalesce(nullif(p->>'functional_class',''), functional_class) end,
      tax_form = case when type = 'expense' then nullif(p->>'tax_form','') end,
      reimbursable = case when type = 'expense' then coalesce((p->>'reimbursable')::boolean, reimbursable) else false end,
      per_mile = case when type = 'expense' then coalesce((p->>'per_mile')::boolean, per_mile) else false end,
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


-- >>> 20261019000800_donor_import.sql
-- =====================================================================
-- BEM Ledger — donor import (CSV). The app parses the file and maps the
-- columns; this function finds existing donors and creates or updates.
-- p: {rows: [{donor fields...}], mode: 'skip'|'update', dry_run: boolean}
--   Matching, in order: donor_number, email, then name + ZIP
--   (organization name, or first + last name).
--   mode 'skip'   = leave existing donors alone (default)
--   mode 'update' = fill in / overwrite fields that the file provides
-- Returns {created, updated, skipped, errors, results:[{row, action, donor_id, name, message}]}
-- =====================================================================
create or replace function import_donors(p jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb; i int := 0; v_match donors; v_action text; v_msg text; v_name text; v_saved jsonb;
  v_mode text := coalesce(nullif(p->>'mode',''), 'skip'); v_dry boolean := coalesce((p->>'dry_run')::boolean, false);
  v_results jsonb := '[]'; c_created int := 0; c_updated int := 0; c_skipped int := 0; c_errors int := 0;
  v_seen text[] := '{}'; v_key text; v_type text;
begin
  if jsonb_typeof(p->'rows') <> 'array' then raise exception 'No rows to import'; end if;
  if v_mode not in ('skip','update') then raise exception 'Unknown import mode'; end if;

  for r in select * from jsonb_array_elements(p->'rows') loop
    i := i + 1; v_match := null; v_msg := null;
    -- clean empty strings to null
    r := (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(r) e(k, v)
           where not (jsonb_typeof(v) = 'string' and trim(v #>> '{}') = ''));
    v_type := coalesce(r->>'donor_type', 'individual');
    v_name := case when v_type in ('individual','household')
                   then trim(concat_ws(' ', r->>'first_name', case when r ? 'spouse_name' then '& ' || (r->>'spouse_name') end, r->>'last_name'))
                   else r->>'organization_name' end;

    if coalesce(v_name, '') = '' then
      v_action := 'error'; v_msg := case when v_type in ('individual','household') then 'No first or last name' else 'No organization name' end;
    elsif v_type not in ('individual','household','church','organization','foundation','business') then
      v_action := 'error'; v_msg := 'Unknown donor type "' || v_type || '"';
    elsif coalesce(r->>'receipt_preference','email') not in ('email','mail','none') then
      v_action := 'error'; v_msg := 'Receipt preference must be email, mail or none';
    else
      -- duplicates inside the file itself
      v_key := lower(coalesce(r->>'email', v_name || '|' || coalesce(r->>'postal_code','')));
      if v_key = any(v_seen) then
        v_action := 'skip'; v_msg := 'Same donor appears earlier in the file';
      else
        v_seen := v_seen || v_key;
        if r ? 'donor_number' then
          select * into v_match from donors where donor_number::text = r->>'donor_number';
        end if;
        if v_match.id is null and r ? 'email' then
          select * into v_match from donors where lower(email) = lower(r->>'email') limit 1;
        end if;
        if v_match.id is null then
          select * into v_match from donors d
           where coalesce(d.postal_code,'') = coalesce(r->>'postal_code','')
             and ((v_type not in ('individual','household') and lower(d.organization_name) = lower(r->>'organization_name'))
               or (v_type in ('individual','household') and lower(coalesce(d.last_name,'')) = lower(coalesce(r->>'last_name',''))
                   and lower(coalesce(d.first_name,'')) = lower(coalesce(r->>'first_name',''))))
           limit 1;
        end if;
        if v_match.id is null then v_action := 'create';
        elsif v_mode = 'update' then v_action := 'update';
        else v_action := 'skip'; v_msg := 'Already exists';
        end if;
      end if;
    end if;

    if not v_dry and v_action in ('create','update') then
      begin
        if v_action = 'create' then
          v_saved := save_donor(r - 'donor_number' - 'id' || jsonb_build_object('donor_type', v_type));
        else
          -- existing values, overlaid with the fields the file provides
          v_saved := save_donor((to_jsonb(v_match) - 'display_name' - 'sort_name') || (r - 'donor_number' - 'id')
                                || jsonb_build_object('id', v_match.id, 'donor_type', v_type));
        end if;
        v_match.id := (v_saved->>'id')::uuid;
      exception when others then
        v_action := 'error'; v_msg := sqlerrm;
      end;
    end if;

    case v_action when 'create' then c_created := c_created + 1; when 'update' then c_updated := c_updated + 1;
                  when 'skip' then c_skipped := c_skipped + 1; else c_errors := c_errors + 1; end case;
    v_results := v_results || jsonb_build_object('row', i, 'action', v_action, 'donor_id', v_match.id,
                   'name', v_name, 'match_name', v_match.display_name, 'match_number', v_match.donor_number, 'message', v_msg);
  end loop;

  if not v_dry then
    perform _log('import', 'donors', null, jsonb_build_object('created', c_created, 'updated', c_updated, 'skipped', c_skipped, 'errors', c_errors));
  end if;
  return jsonb_build_object('created', c_created, 'updated', c_updated, 'skipped', c_skipped, 'errors', c_errors, 'results', v_results);
end $$;


-- >>> 20261019000850_recurring_payments.sql
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


-- >>> 20261019000860_tax_treatment.sql
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


-- >>> 20261019000870_bills_employees.sql
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


-- >>> 20261019000900_supabase_security.sql
-- =====================================================================
-- BEM Ledger — Supabase-only security layer.
-- NOT run by the local (in-browser) database; run it on Supabase after
-- the other migration files.
--
--   * Only users listed in app_admins can read or change anything.
--   * Row-level security on every table; anonymous visitors get nothing.
--   * current_actor() records the signed-in user's email on every posting.
-- =====================================================================

create table if not exists app_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where user_id = auth.uid())
$$;

create or replace function current_actor() returns text
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', auth.uid()::text, 'system')
$$;

-- Row-level security: admins only, on every table in public.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' and tablename <> 'app_admins' loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

alter table app_admins enable row level security;
drop policy if exists admins_read_self on app_admins;
create policy admins_read_self on app_admins for select to authenticated using (user_id = auth.uid());

-- Block anonymous access to the API functions. (RLS already hides the
-- data; this keeps the functions themselves private as well.)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from anon, public', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- Who am I? Used by the app after sign-in.
create or replace function whoami(p jsonb) returns jsonb
language sql stable as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email', 'is_admin', is_admin())
$$;
revoke execute on function whoami(jsonb) from anon, public;
grant execute on function whoami(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- After running this file, make yourself an administrator:
--   1. Authentication > Users > Add user (your email + a password)
--   2. Run:
--      insert into app_admins (user_id, email)
--      select id, email from auth.users where email = 'you@example.org';
-- ---------------------------------------------------------------------
