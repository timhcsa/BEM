import React, { useMemo, useState } from 'react';
import { go, routeQuery, useApp, useRpc } from '../lib/store';
import { METHODS, acct, date, download, money, periods, toCsv, today, type Period } from '../lib/format';
import Form1099 from './Form1099';
import W2 from './W2';
import { Card, Empty, ErrorBox, FundSelect, Loading, Money, PageHeader, PeriodPicker } from '../components/ui';

const REPORTS: [string, string, string][] = [
  ['position', 'Statement of Financial Position', 'Balance sheet: what BEM has, by net asset class, on a date.'],
  ['activities', 'Statement of Activities', 'Income and expenses for a period, with releases from restriction (ASC 958).'],
  ['functional', 'Statement of Functional Expenses', 'Expenses split between program, management & general, and fundraising.'],
  ['funds', 'Fund Activity Summary', 'Every fund: beginning balance, gifts, admin fees, payments, ending balance.'],
  ['statements', 'Year-end donor tax statements', 'A contribution statement for every donor, with the IRS acknowledgment wording. Print, save as PDF, or filter mail vs. email.'],
  ['w2', 'W-2 worksheet for missionaries', 'Salary, housing allowance, medical and expense reimbursements per employee for the year, ready for your payroll service or CPA.'],
  ['1099', '1099s for contractors', 'Form 1099-NEC/MISC totals for non-employees, W-9 checks, recipient copies and an e-file CSV.'],
  ['trial', 'Trial Balance', 'Debits equal credits check, by account.'],
  ['ledger', 'General Ledger', 'Every journal line, filterable by account and fund. Exports to CSV for your CPA.'],
];

function OrgHeader({ title, sub }: { title: string; sub: string }) {
  const { lookups } = useApp();
  return (
    <div className="report-head">
      <img className="report-logo" src={lookups?.settings?.logo_url || '/bem-logo.jpg'} alt="" />
      <div className="org">{lookups?.settings?.org_name}</div>
      <h1>{title}</h1>
      <div className="muted">{sub}</div>
    </div>
  );
}

function Toolbar({ children, csv }: { children?: React.ReactNode; csv?: () => void }) {
  return (
    <div className="toolbar no-print">
      <a href="#/reports">← Reports</a>
      {children}
      <div className="spacer" />
      {csv && <button className="btn" onClick={csv}>Export CSV</button>}
      <button className="btn" onClick={() => window.print()}>Print / PDF</button>
    </div>
  );
}

function Position() {
  const [asOf, setAsOf] = useState(today());
  const { data: r, error } = useRpc<any>('report_financial_position', { as_of: asOf });
  return (
    <div className="report">
      <Toolbar><input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></Toolbar>
      <ErrorBox error={error} />
      {r && (
        <>
          <OrgHeader title="Statement of Financial Position" sub={`As of ${date(r.as_of)}`} />
          <table className="table report-table">
            <tbody>
              <tr className="section"><td colSpan={2}>Assets</td></tr>
              {r.assets.map((a: any) => <tr key={a.code}><td className="indent">{a.name}</td><td className="num">{acct(a.amount)}</td></tr>)}
              <tr className="total"><td>Total assets</td><td className="num">{acct(r.total_assets)}</td></tr>
              <tr className="section"><td colSpan={2}>Liabilities</td></tr>
              {r.liabilities.length ? r.liabilities.map((a: any) => <tr key={a.code}><td className="indent">{a.name}</td><td className="num">{acct(a.amount)}</td></tr>)
                : <tr><td className="indent muted">None</td><td className="num">{acct(0)}</td></tr>}
              <tr className="section"><td colSpan={2}>Net assets</td></tr>
              <tr><td className="indent">Without donor restrictions</td><td className="num">{acct(r.net_assets_without)}</td></tr>
              <tr><td className="indent">With donor restrictions</td><td className="num">{acct(r.net_assets_with)}</td></tr>
              <tr className="subtotal"><td>Total net assets</td><td className="num">{acct(Number(r.net_assets_without) + Number(r.net_assets_with))}</td></tr>
              <tr className="total double"><td>Total liabilities and net assets</td><td className="num">{acct(Number(r.total_liabilities) + Number(r.net_assets_without) + Number(r.net_assets_with))}</td></tr>
            </tbody>
          </table>
          <h3 className="section-label">Net assets by fund</h3>
          <table className="table report-table">
            <tbody>
              {['without', 'with'].map((cls) => (
                <React.Fragment key={cls}>
                  <tr className="section"><td colSpan={2}>{cls === 'with' ? 'With donor restrictions' : 'Without donor restrictions'}</td></tr>
                  {r.funds.filter((f: any) => f.restriction === cls).map((f: any) => <tr key={f.code}><td className="indent">{f.name}</td><td className="num">{acct(f.amount)}</td></tr>)}
                </React.Fragment>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}

function Activities() {
  const [p, setP] = useState<Period>(periods().ytd);
  const { data: r, error } = useRpc<any>('report_activities', { from: p.from, to: p.to });
  return (
    <div className="report">
      <Toolbar><PeriodPicker value={p} onChange={setP} /></Toolbar>
      <ErrorBox error={error} />
      {r && (
        <>
          <OrgHeader title="Statement of Activities" sub={`${date(r.from)} through ${date(r.to)}`} />
          <table className="table report-table three">
            <thead><tr><th /><th className="num">Without donor restrictions</th><th className="num">With donor restrictions</th><th className="num">Total</th></tr></thead>
            <tbody>
              <tr className="section"><td colSpan={4}>Revenue and support</td></tr>
              {r.revenue.map((x: any) => <tr key={x.code}><td className="indent">{x.name}</td><td className="num">{acct(x.without)}</td><td className="num">{acct(x.with)}</td><td className="num">{acct(x.total)}</td></tr>)}
              <tr><td className="indent">Net assets released from restrictions</td><td className="num">{acct(r.released)}</td><td className="num">{acct(-r.released)}</td><td className="num">{acct(0)}</td></tr>
              <tr className="subtotal"><td>Total revenue, support and reclassifications</td><td className="num">{acct(Number(r.revenue_without) + Number(r.released))}</td>
                <td className="num">{acct(Number(r.revenue_with) - Number(r.released))}</td><td className="num">{acct(Number(r.revenue_without) + Number(r.revenue_with))}</td></tr>
              <tr className="section"><td colSpan={4}>Expenses</td></tr>
              {r.expenses.map((x: any) => <tr key={x.code}><td className="indent">{x.name}</td><td className="num">{acct(x.amount)}</td><td className="num" /><td className="num">{acct(x.amount)}</td></tr>)}
              <tr className="subtotal"><td>Total expenses</td><td className="num">{acct(r.total_expenses)}</td><td className="num">{acct(0)}</td><td className="num">{acct(r.total_expenses)}</td></tr>
              {(Number(r.opening_entries.without) || Number(r.opening_entries.with)) ? (
                <tr><td>Opening balances recorded in this period</td><td className="num">{acct(r.opening_entries.without)}</td><td className="num">{acct(r.opening_entries.with)}</td>
                  <td className="num">{acct(Number(r.opening_entries.without) + Number(r.opening_entries.with))}</td></tr>) : null}
              <tr className="total"><td>Change in net assets</td><td className="num">{acct(r.change_without)}</td><td className="num">{acct(r.change_with)}</td><td className="num">{acct(Number(r.change_without) + Number(r.change_with))}</td></tr>
              <tr><td>Net assets, beginning of period</td><td className="num">{acct(r.beginning_without)}</td><td className="num">{acct(r.beginning_with)}</td><td className="num">{acct(Number(r.beginning_without) + Number(r.beginning_with))}</td></tr>
              <tr className="total double"><td>Net assets, end of period</td><td className="num">{acct(r.ending_without)}</td><td className="num">{acct(r.ending_with)}</td><td className="num">{acct(Number(r.ending_without) + Number(r.ending_with))}</td></tr>
            </tbody>
          </table>
          <p className="muted small">Administrative fees moved from missionary accounts to the General Fund are internal and net to zero; they appear here as part of net assets released from restrictions.</p>
        </>
      )}
    </div>
  );
}

function Functional() {
  const [p, setP] = useState<Period>(periods().ytd);
  const { data: r, error } = useRpc<any>('report_functional_expenses', { from: p.from, to: p.to });
  return (
    <div className="report">
      <Toolbar><PeriodPicker value={p} onChange={setP} /></Toolbar>
      <ErrorBox error={error} />
      {r && (
        <>
          <OrgHeader title="Statement of Functional Expenses" sub={`${date(r.from)} through ${date(r.to)}`} />
          <table className="table report-table four">
            <thead><tr><th /><th className="num">Program services</th><th className="num">Management & general</th><th className="num">Fundraising</th><th className="num">Total</th></tr></thead>
            <tbody>
              {r.rows.map((x: any) => <tr key={x.code}><td>{x.name}</td><td className="num">{acct(x.program)}</td><td className="num">{acct(x.management_general)}</td><td className="num">{acct(x.fundraising)}</td><td className="num">{acct(x.total)}</td></tr>)}
              <tr className="total double"><td>Total expenses</td><td className="num">{acct(r.totals.program)}</td><td className="num">{acct(r.totals.management_general)}</td><td className="num">{acct(r.totals.fundraising)}</td><td className="num">{acct(r.totals.total)}</td></tr>
              {Number(r.totals.total) > 0 && <tr className="muted"><td>Percent of total</td>{['program', 'management_general', 'fundraising'].map((k) => <td key={k} className="num">{((Number(r.totals[k]) / Number(r.totals.total)) * 100).toFixed(1)}%</td>)}<td className="num">100%</td></tr>}
            </tbody>
          </table>
        </>
      )}
    </div>
  );
}

function FundActivity() {
  const [p, setP] = useState<Period>(periods().ytd);
  const { data: r, error } = useRpc<any>('report_fund_activity', { from: p.from, to: p.to });
  const rows: any[] = r?.rows ?? [];
  const sum = (k: string) => rows.reduce((s, x) => s + Number(x[k]), 0);
  return (
    <div className="report">
      <Toolbar csv={() => download('fund-activity.csv', toCsv(rows, [['code', 'Code'], ['name', 'Fund'], ['restriction', 'Class'], ['beginning', 'Beginning'],
        ['opening', 'Opening entries'], ['revenue', 'Gifts & income'], ['admin_fees', 'Admin fees'], ['transfers', 'Transfers'], ['expenses', 'Payments'], ['ending', 'Ending']]), 'text/csv')}>
        <PeriodPicker value={p} onChange={setP} />
      </Toolbar>
      <ErrorBox error={error} />
      {r && (
        <>
          <OrgHeader title="Fund Activity Summary" sub={`${date(r.from)} through ${date(r.to)}`} />
          <table className="table report-table wide">
            <thead><tr><th>Fund</th><th className="num">Beginning</th>{sum('opening') ? <th className="num">Opening entries</th> : null}<th className="num">Gifts & income</th><th className="num">Admin fees</th><th className="num">Transfers</th><th className="num">Payments</th><th className="num">Ending</th></tr></thead>
            <tbody>
              {rows.map((x) => (
                <tr key={x.fund_id} className="clickable" onClick={() => go(`funds/${x.fund_id}`)}>
                  <td>{x.name}<div className="muted small">{x.restriction === 'with' ? 'With restrictions' : 'Without restrictions'}</div></td>
                  <td className="num">{acct(x.beginning)}</td>{sum('opening') ? <td className="num">{acct(x.opening)}</td> : null}<td className="num">{acct(x.revenue)}</td><td className="num">{acct(x.admin_fees)}</td>
                  <td className="num">{acct(x.transfers)}</td><td className="num">{acct(-x.expenses)}</td><td className="num strong">{acct(x.ending)}</td>
                </tr>
              ))}
              <tr className="total double"><td>All funds</td><td className="num">{acct(sum('beginning'))}</td>{sum('opening') ? <td className="num">{acct(sum('opening'))}</td> : null}<td className="num">{acct(sum('revenue'))}</td>
                <td className="num">{acct(sum('admin_fees'))}</td><td className="num">{acct(sum('transfers'))}</td><td className="num">{acct(-sum('expenses'))}</td><td className="num">{acct(sum('ending'))}</td></tr>
            </tbody>
          </table>
          <p className="muted small">Admin fees and transfers net to $0.00 across all funds: they move money between funds without changing the bank balance.</p>
        </>
      )}
    </div>
  );
}

function Trial() {
  const [asOf, setAsOf] = useState(today());
  const { data: r, error } = useRpc<any>('report_trial_balance', { as_of: asOf });
  return (
    <div className="report">
      <Toolbar><input type="date" value={asOf} onChange={(e) => setAsOf(e.target.value)} /></Toolbar>
      <ErrorBox error={error} />
      {r && (
        <>
          <OrgHeader title="Trial Balance" sub={`As of ${date(r.as_of)}`} />
          <table className="table report-table three">
            <thead><tr><th>Account</th><th className="num">Debit</th><th className="num">Credit</th></tr></thead>
            <tbody>
              {r.rows.map((x: any) => <tr key={x.code}><td>{x.code} · {x.name}</td><td className="num">{Number(x.debit) ? money(x.debit) : ''}</td><td className="num">{Number(x.credit) ? money(x.credit) : ''}</td></tr>)}
              <tr className="total double"><td>Totals {r.total_debit === r.total_credit ? '✓' : '— OUT OF BALANCE'}</td><td className="num">{money(r.total_debit)}</td><td className="num">{money(r.total_credit)}</td></tr>
            </tbody>
          </table>
          <p className="muted small">Interfund accounts (39xx) always net to zero across funds. Revenue and expense accounts are not closed out at year-end in this view; the statements above handle that.</p>
        </>
      )}
    </div>
  );
}

function Ledger() {
  const { lookups } = useApp();
  const [p, setP] = useState<Period>(periods().this_month);
  const [accountId, setAccountId] = useState('');
  const [fundId, setFundId] = useState('');
  const { data: r, error, loading } = useRpc<any>('report_general_ledger', { from: p.from, to: p.to, account_id: accountId, fund_id: fundId });
  const rows: any[] = r?.rows ?? [];
  return (
    <div className="report">
      <Toolbar csv={() => download(`general-ledger-${p.from}-to-${p.to}.csv`, toCsv(rows, [['entry_number', 'Entry #'], ['entry_date', 'Date'], ['source_type', 'Source'], ['label', 'Description'],
        ['account_code', 'Account #'], ['account_name', 'Account'], ['fund_name', 'Fund'], ['debit', 'Debit'], ['credit', 'Credit'], ['memo', 'Memo'], ['created_by', 'Entered by']]), 'text/csv')}>
        <PeriodPicker value={p} onChange={setP} />
        <select value={accountId} onChange={(e) => setAccountId(e.target.value)}>
          <option value="">All accounts</option>
          {(lookups?.accounts ?? []).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
        </select>
        <FundSelect funds={lookups?.funds ?? []} value={fundId} onChange={setFundId} includeInactive placeholder="All funds" />
      </Toolbar>
      <ErrorBox error={error} />
      <OrgHeader title="General Ledger" sub={`${date(p.from)} through ${date(p.to)}`} />
      {loading && !r ? <Loading /> : rows.length ? (
        <table className="table report-table wide compact">
          <thead><tr><th>Entry</th><th>Date</th><th>Description</th><th>Account</th><th>Fund</th><th className="num">Debit</th><th className="num">Credit</th></tr></thead>
          <tbody>{rows.map((x, i) => (
            <tr key={i} className={i > 0 && rows[i - 1].entry_number === x.entry_number ? 'cont' : 'first'}>
              <td className="muted">{x.entry_number}</td><td className="nowrap">{date(x.entry_date)}</td><td>{x.label}{x.memo && <div className="muted small">{x.memo}</div>}</td>
              <td className="small">{x.account_code} · {x.account_name}</td><td className="small">{x.fund_name}</td>
              <td className="num">{Number(x.debit) ? money(x.debit) : ''}</td><td className="num">{Number(x.credit) ? money(x.credit) : ''}</td>
            </tr>
          ))}</tbody>
          <tfoot><tr className="total"><td colSpan={5}>Totals</td><td className="num">{money(rows.reduce((s, x) => s + Number(x.debit), 0))}</td><td className="num">{money(rows.reduce((s, x) => s + Number(x.credit), 0))}</td></tr></tfoot>
        </table>
      ) : <Empty>No entries in this period.</Empty>}
    </div>
  );
}

function Statements() {
  const q = routeQuery();
  const [year, setYear] = useState<number>(Number(q.get('year')) || new Date().getFullYear() - 1);
  const donorId = q.get('donor') ?? '';
  const [delivery, setDelivery] = useState('all');
  const { data: r, error, loading } = useRpc<any>('report_donor_statements', { year, donor_id: donorId, delivery });
  const s = r?.settings ?? {};
  const list: any[] = r?.statements ?? [];
  return (
    <div className="report">
      <Toolbar>
        <select value={year} onChange={(e) => setYear(Number(e.target.value))}>
          {Array.from({ length: 6 }, (_, i) => new Date().getFullYear() - i).map((y) => <option key={y} value={y}>{y}</option>)}
        </select>
        {!donorId && (
          <select value={delivery} onChange={(e) => setDelivery(e.target.value)}>
            <option value="all">All donors</option>
            <option value="mail">Donors who get statements by mail</option>
            <option value="email">Donors who get statements by email</option>
            <option value="none">Donors who asked for no receipts</option>
          </select>
        )}
        {donorId ? <a href={`#/reports/statements?year=${year}`}>Show all donors</a> : <span className="muted small">{list.length} statements · each prints on its own page</span>}
        {!donorId && list.length > 0 && (
          <button className="btn" onClick={() => download(`giving-${year}-email-list.csv`, toCsv(list.map((x) => ({ name: x.donor.display_name, email: x.donor.email, preference: x.donor.receipt_preference, total: x.total })),
            [['name', 'Donor'], ['email', 'Email'], ['preference', 'Receipt preference'], ['total', `${year} total`]]), 'text/csv')}>Donor list CSV</button>
        )}
      </Toolbar>
      <ErrorBox error={error} />
      {loading && !r ? <Loading /> : list.length ? list.map((st) => {
        const d = st.donor;
        return (
          <article key={d.id} className="giving-statement">
            <header>
              <div>
                <img className="stmt-logo" src={s.logo_url || '/bem-logo.jpg'} alt="" />
                <div className="org-name">{s.org_name}</div>
                <div className="small">{s.address}</div>
                <div className="small">{[s.phone, s.website].filter(Boolean).join(' · ')}</div>
                {s.ein && <div className="small">EIN {s.ein} · a 501(c)(3) tax-exempt organization</div>}
              </div>
              <div className="right"><h2>{year} Giving Statement</h2><div className="small">Issued {date(today())}</div></div>
            </header>
            <div className="address-block">
              <div>{d.display_name}</div>
              {d.contact_name && <div>Attn: {d.contact_name}</div>}
              {d.address_line1 && <div>{d.address_line1}</div>}
              {d.address_line2 && <div>{d.address_line2}</div>}
              <div>{[d.city, d.state].filter(Boolean).join(', ')} {d.postal_code}</div>
            </div>
            <p>{d.salutation ? `${d.salutation},` : `Dear ${d.display_name},`}</p>
            <p>Thank you for your faithful support of {s.org_name} in {year}. Your gifts encourage pastors, churches and missionaries. Below is a record of your contributions for your tax records.</p>
            <table className="table compact">
              <thead><tr><th>Date</th><th>Gift #</th><th>Method</th><th>Designation</th><th className="num">Amount</th></tr></thead>
              <tbody>{(st.gifts ?? []).map((g: any) => (
                <tr key={g.gift_number}><td>{date(g.gift_date)}</td><td>{g.gift_number}</td><td>{METHODS[g.method]}{g.reference ? ` #${g.reference}` : ''}</td><td>{g.designation}</td><td className="num">{money(g.amount)}</td></tr>
              ))}</tbody>
              <tfoot><tr className="total"><td colSpan={4}>Total cash contributions for {year}</td><td className="num">{money(st.total)}</td></tr></tfoot>
            </table>
            {st.noncash?.length > 0 && (
              <>
                <h3 className="section-label">Non-cash contributions</h3>
                <table className="table compact">
                  <thead><tr><th>Date</th><th>Gift #</th><th>Description of property</th><th>Designation</th></tr></thead>
                  <tbody>{st.noncash.map((g: any) => <tr key={g.gift_number}><td>{date(g.gift_date)}</td><td>{g.gift_number}</td><td>{g.description}</td><td>{g.designation}</td></tr>)}</tbody>
                </table>
                <p className="small">{s.org_name} does not place a value on non-cash gifts. Determining the value for tax purposes is the donor's responsibility.</p>
              </>
            )}
            <p className="ack">{s.receipt_note}</p>
            <p className="small muted">Gifts designated for a missionary or ministry are accepted with the understanding that {s.org_name} retains full discretion and control over their use, consistent with its exempt purposes.</p>
            <div className="no-print stmt-actions">
              <a className="btn small" href={`#/reports/statements?donor=${d.id}&year=${year}`}>Print only this statement</a>
              {d.email && <a className="btn small" href={`mailto:${d.email}?subject=${encodeURIComponent(`${year} giving statement from ${s.org_name}`)}`}>Email {d.email}</a>}
            </div>
            <div className="signature">
              <div className="line" />
              <div className="small">{s.receipt_signer || 'Treasurer'}</div>
            </div>
          </article>
        );
      }) : <Empty>No gifts recorded for {year}{donorId ? ' for this donor' : ''}.</Empty>}
    </div>
  );
}

export default function Reports({ sub }: { sub?: string }) {
  const comps: Record<string, React.FC> = { '1099': Form1099, w2: W2, position: Position, activities: Activities, functional: Functional, funds: FundActivity, trial: Trial, ledger: Ledger, statements: Statements };
  const C = sub ? comps[sub] : null;
  if (C) return <C />;
  return (
    <div>
      <PageHeader title="Reports" subtitle="Nonprofit (ASC 958) financial statements, fund reports and donor statements. Every report prints cleanly or saves as PDF from the print dialog." />
      <div className="report-grid">
        {REPORTS.map(([k, t, d]) => (
          <a key={k} className="report-card" href={`#/reports/${k}`}><strong>{t}</strong><span>{d}</span></a>
        ))}
        <a className="report-card" href="#/missionaries"><strong>Missionary account statements</strong><span>Open a missionary, pick the period, and print.</span></a>
      </div>
    </div>
  );
}
