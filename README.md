# BEM Ledger

Fund accounting for **Barnabas Enrichment Ministries**, branded to match barnabasenrichmentministries.org (BEM logo, blue and leaf green, Playfair Display and Inter). BEM's six staff missionaries from the website's Staff page are built in, with their photos (`public/staff/`) and bios, each with their own missionary account. It is built to replace QuickBooks. It's a simple web app for BEM's administrators, set up for nonprofit GAAP (ASC 958).

- **Gifts**: find the donor, split a gift across the General Fund, the Conference Fund, missionary accounts or other funds, and save.
- **Missionary accounts**: a photo grid. Click a photo to see the balance, gifts, the admin fee, payments, supporters and a printable statement.
- **Admin fee**: 10% of each gift to a missionary, capped at **$250 per missionary per calendar month**. It moves to the General Fund automatically and is recalculated when a gift is entered or voided. The rate and cap can be changed for each missionary.
- **Deposits**: group gifts into bank deposits, so the ledger matches the bank statement line for line.
- **Payments**: support, reimbursements and expenses, each tagged with a functional class (program, management & general, fundraising). A payment that would take a fund below zero is blocked.
- **Dashboard**: every fund, with **Total of all funds = bank balance + undeposited gifts**.
- **Bank reconciliation**: tick off the statement until the difference is $0.00.
- **Reports**: Statement of Financial Position, Statement of Activities (with and without donor restrictions, releases), Statement of Functional Expenses, Fund Activity, Trial Balance, General Ledger (CSV for your CPA), and year-end **donor giving statements** with the IRS acknowledgment wording.
- **Donor import/export**: import donors from any CSV (Excel, Numbers, another system). Columns are matched automatically, you check a preview, and duplicates are found by donor #, email or name + ZIP. You choose whether to skip or update them. The export uses the same columns, so a file can go out and back in.
- **Year-end tax forms**: donor giving statements (cash total, non-cash gifts described without a value, and the IRS acknowledgment wording, filterable by mail or email). **Forms 1099-NEC/MISC** for missionaries and contractors: W-9 details on the **Payees** page, the $600 (2025) and $2,000 (2026) thresholds, card payments left out (1099-K), the housing allowance and reimbursements left out of box 1, printable recipient copies, and an e-file CSV for the IRS IRIS portal or a filing service.
- **Taxable vs. non-taxable missionary payments**: every line of a payment to a missionary is marked **Taxable** (salary, extra funds for personal use: 1099-NEC box 1), **Non-taxable reimbursement** (business expenses with receipts: not reported) or **Housing allowance**. Defaults come from the category, including the new 5030 *Additional Funds* for extra salary or personal requests, and can be changed per line. The 1099 report has a per-payment "details" view showing what was counted.
- **Recurring payments**: set up monthly salary or support once (salary and housing allowance as separate lines, a day of the month, start and optional end month). Each month the **Recurring payments** tab and the dashboard list what's due. Review the list and click **Post**. Nothing posts on its own, a month can't be paid twice, and funds that would be overdrawn are flagged.
- **Controls**: double-entry with every fund balanced on its own. Posted entries can't be edited or deleted; mistakes are voided with a reversing entry and a reason. You can close the books through a date, and every entry records who made it.

## Run it on your Mac (no database setup)

You need Node.js 20 or later (you already have it).

```bash
cd ~/Documents/GitHub/bem-ledger
npm install
npm run dev
```

The browser opens at http://localhost:5180. With no Supabase settings, the app runs a **real PostgreSQL database inside the browser** (PGlite), using the same SQL files Supabase will use. The data is saved in that browser on that Mac.

- To explore: **Settings → Data & backup → Load sample data**. It adds made-up donors and three months of activity for BEM's real missionaries.
- To start over: **Settings → Data & backup → Erase everything**.
- **Back up often.** Clearing the browser's site data erases the local database. **Download data (.sql)** saves everything to a file, and **Restore** loads it back.

## Going live: Supabase + Netlify

### 1. Supabase (database and logins)
1. Create a project at supabase.com. Copy the **Project URL** and the **anon public key** from Project Settings → API.
2. Open the **SQL Editor** and run the files in `supabase/migrations/` **in filename order**, including the last one, `…_supabase_security.sql`.
   Or run `npm run sql:bundle` and paste `supabase/deploy_all.sql` in one go.
3. **Authentication → Users → Add user** with your email and a password. Then make yourself an administrator:
   ```sql
   insert into app_admins (user_id, email)
   select id, email from auth.users where email = 'you@example.org';
   ```
4. Authentication → Sign In / Providers: turn **off** "Allow new users to sign up".
5. *(Optional) To bring over what you entered locally:* in the local app, go to **Settings → Data & backup → Download data (.sql)**. Paste that file into the Supabase SQL Editor and run it. It only runs on an empty ledger.
   Don't load the sample data into Supabase.

### 2. Netlify (the website)
1. Push this folder to GitHub, then in Netlify choose **Add new site → Import from Git**. `netlify.toml` already sets the build.
2. Under **Site settings → Environment variables**, add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY`, then redeploy.
3. In Supabase → Authentication → URL Configuration, set the **Site URL** to your Netlify address so password-reset emails work.

To try Supabase from your Mac before deploying, put the same two values in a file named `.env.local` and run `npm run dev`.

> If you add new SQL functions later, re-run `…_supabase_security.sql` so they get the same "administrators only" rules.

## How the accounting works

| Event | Entry (per fund) |
|---|---|
| Gift received | Dr 1050 Undeposited Gifts / Cr 4000 or 4010 Contributions |
| Admin fee | Missionary fund: Dr 3910 Interfund / Cr 1000 Checking · General Fund: Dr 1000 / Cr 3910 |
| Deposit | Dr 1000 Checking / Cr 1050 Undeposited Gifts |
| Payment | Dr 5xxx–6xxx Expense (+ functional class) / Cr 1000 Checking |
| Transfer | From fund: Dr 3920 / Cr 1000 · To fund: Dr 1000 / Cr 3920 |
| Opening balance | Dr 1000 / Cr 3000 (without) or 3100 (with donor restrictions) |

- Each fund's balance is its share of the pooled bank account. Interfund entries net to $0.00 across the organization.
- Missionary, Conference and Triage funds are classified **with donor restrictions**. The Statement of Activities shows money they spend (and admin fees they pay) as *net assets released from restrictions*. **Have BEM's CPA confirm these classifications.** The class can be changed per fund until the fund has activity.
- A gift voided **after** it was deposited (for example a returned check) is reversed against Checking, so it shows on the next reconciliation.

## Future: connecting the bank

The `bank_transactions` table is already in place for imported bank activity (CSV or a service such as Plaid), with a link to the matching journal entry. A bank feed would mean adding a Supabase Edge Function that fills this table, plus a screen that suggests matches on the reconciliation page. The ledger itself doesn't need to change.

## Project layout

```
supabase/migrations/   The database: schema, posting rules, reports (run these on Supabase)
supabase/sample_data.sql   Demo data (local testing only)
supabase/tests/        Accounting rule tests (psql -f supabase/tests/accounting_tests.sql)
src/lib/api.ts         The one door to the database: rpc('function', params), local or Supabase
src/lib/localDb.ts     The in-browser PostgreSQL used for local mode
src/pages/             Screens
```

All business rules live in the database functions, so the screens can't post an unbalanced or back-dated entry, even by mistake.
