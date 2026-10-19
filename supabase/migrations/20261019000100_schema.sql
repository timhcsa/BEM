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
