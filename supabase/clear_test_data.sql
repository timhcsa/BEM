-- =====================================================================
-- BEM Ledger — CLEAR ALL TRANSACTIONS AND DONORS (start fresh).
-- Run this once, after testing and before entering real data.
-- Keeps: chart of accounts, funds, missionaries (with photos), settings,
--        administrator logins, and missionary W-9 records.
-- Removes: every gift, deposit, payment, transfer, journal entry,
--          reconciliation, recurring payment, donor, non-missionary payee
--          and the change log. THIS CANNOT BE UNDONE.
-- Supabase: SQL Editor > New query > paste > Run.
-- (Posted entries can't normally be deleted; TRUNCATE is used on purpose.)
-- =====================================================================
begin;
truncate reconciliation_items, reconciliations, recurring_runs, recurring_payment_lines, recurring_payments,
         bank_transactions, gift_lines, gifts, deposits, disbursement_lines, disbursements, transfers,
         journal_lines, journal_entries, donors, audit_log restart identity cascade;
delete from payees where missionary_id is null;
-- remove the made-up W-9 details from the sample data (real ones you entered are kept)
update payees set legal_name = null, tin_type = null, tin = null, w9_on_file = false,
                  address_line1 = null, address_line2 = null, city = null, state = null, postal_code = null
 where tin in ('123456789', '987654321');
update settings set closed_through = null,
       ein = case when ein = '00-0000000' then null else ein end,
       receipt_signer = case when receipt_signer = 'Treasurer, Barnabas Enrichment Ministries' then null else receipt_signer end
 where id = 1;
commit;

select 'cleared' as status,
       (select count(*) from journal_entries) as entries,
       (select count(*) from donors) as donors,
       (select count(*) from missionaries) as missionaries,
       (select count(*) from funds) as funds;
