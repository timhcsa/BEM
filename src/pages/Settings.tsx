import React, { useEffect, useState } from 'react';
import { MODE, buildDataExportSql, loadSampleData, resetLocalDatabase, rpc, runLocalSql } from '../lib/api';
import { useApp, useRpc, type Account } from '../lib/store';
import { FUNCTIONAL, date, download, money, num, today } from '../lib/format';
import { Badge, Card, ErrorBox, Field, Modal, Money, MoneyInput, PageHeader } from '../components/ui';

const TABS: [string, string][] = [['organization', 'Organization'], ['opening', 'Opening balances'], ['close', 'Close the books'],
  ['accounts', 'Chart of accounts'], ['data', 'Data & backup'], ['audit', 'Change log']];

function Organization() {
  const { lookups, refresh, toast } = useApp();
  const [s, setS] = useState<any>(lookups?.settings ?? {});
  useEffect(() => { if (lookups) setS(lookups.settings); }, [lookups]);
  const set = (k: string) => (e: any) => setS({ ...s, [k]: e.target.value });
  return (
    <Card title="Organization">
      <div className="form-grid">
        <Field label="Legal name" wide><input value={s.org_name ?? ''} onChange={set('org_name')} /></Field>
        <Field label="EIN" hint="Printed on giving statements"><input value={s.ein ?? ''} onChange={set('ein')} placeholder="00-0000000" /></Field>
        <Field label="Phone"><input value={s.phone ?? ''} onChange={set('phone')} /></Field>
        <Field label="Mailing address" wide><input value={s.address ?? ''} onChange={set('address')} /></Field>
        <Field label="Website"><input value={s.website ?? ''} onChange={set('website')} /></Field>
        <Field label="Logo web address (optional)"><input value={s.logo_url ?? ''} onChange={set('logo_url')} /></Field>
        <Field label="Fiscal year starts">
          <select value={s.fiscal_year_start_month ?? 1} onChange={set('fiscal_year_start_month')}>
            {Array.from({ length: 12 }, (_, i) => <option key={i + 1} value={i + 1}>{new Date(2000, i, 1).toLocaleString('en-US', { month: 'long' })}</option>)}
          </select>
        </Field>
      </div>
      <h3 className="section-label">Missionary administrative fee (defaults)</h3>
      <div className="form-grid">
        <Field label="Rate" hint="0.10 = 10%. Can be changed per missionary."><input inputMode="decimal" value={s.default_admin_fee_rate ?? ''} onChange={set('default_admin_fee_rate')} /></Field>
        <Field label="Maximum per missionary per month"><MoneyInput value={String(s.default_admin_fee_cap ?? '')} onChange={(v) => setS({ ...s, default_admin_fee_cap: v })} /></Field>
      </div>
      <p className="muted small">Changing the rate or cap affects gifts entered from now on (and any month that is recalculated because a gift in it is entered or voided).</p>
      <h3 className="section-label">Form 1099</h3>
      <div className="form-grid">
        <Field label="1099-NEC threshold for 2027 and later" hint="$600 through 2025, $2,000 for 2026, then indexed for inflation. Update when the IRS announces the new figure.">
          <MoneyInput value={String(s.form1099_threshold ?? '2000')} onChange={(v) => setS({ ...s, form1099_threshold: v })} />
        </Field>
      </div>
      <h3 className="section-label">Giving statements</h3>
      <div className="form-grid">
        <Field label="Signed by" wide><input value={s.receipt_signer ?? ''} onChange={set('receipt_signer')} placeholder="Name, Treasurer" /></Field>
        <Field label="Acknowledgment wording" wide hint="IRS wording for gifts to a religious organization when nothing was given in return.">
          <textarea rows={2} value={s.receipt_note ?? ''} onChange={set('receipt_note')} />
        </Field>
      </div>
      <div className="form-actions"><button className="btn primary" onClick={async () => {
        try { await rpc('save_settings', { ...s, default_admin_fee_cap: num(s.default_admin_fee_cap), form1099_threshold: num(s.form1099_threshold ?? 2000) }); refresh(); toast('Settings saved'); } catch (e: any) { toast(e.message, 'error'); }
      }}>Save</button></div>
    </Card>
  );
}

function Opening() {
  const { lookups, refresh, toast } = useApp();
  const funds = (lookups?.funds ?? []).filter((f) => f.active);
  const [d, setD] = useState(today());
  const [amts, setAmts] = useState<Record<string, string>>({});
  const total = Object.values(amts).reduce((s, v) => s + num(v), 0);
  const [err, setErr] = useState<string | null>(null);
  return (
    <Card title="Opening balances">
      <p>Use this once, when you switch from QuickBooks. Enter each fund's balance <strong>as of the close of business on the day before</strong> you start entering transactions here. The total should equal the bank's balance on that day <em>plus</em> any gifts received but not yet deposited (if you have those, enter them as gifts instead).</p>
      <p className="muted small">Tip: pick a month-end (for example, the last day of the month you reconciled in QuickBooks) so your first bank reconciliation here is clean. Add your missionaries first so their funds appear below.</p>
      <div className="form-grid"><Field label="Balances as of"><input type="date" value={d} onChange={(e) => setD(e.target.value)} /></Field></div>
      <table className="table">
        <thead><tr><th>Fund</th><th>Class</th><th className="num">Current balance here</th><th style={{ width: 180 }}>Opening amount</th></tr></thead>
        <tbody>{funds.map((f) => (
          <tr key={f.id}><td>{f.name}</td><td className="small">{f.restriction === 'with' ? 'With restrictions' : 'Without restrictions'}</td>
            <td className="num muted"><Money v={f.balance} /></td>
            <td><MoneyInput value={amts[f.id] ?? ''} onChange={(v) => setAmts({ ...amts, [f.id]: v })} /></td></tr>
        ))}</tbody>
        <tfoot><tr className="total"><td colSpan={3}>Total (should equal the bank balance)</td><td className="num">{money(total)}</td></tr></tfoot>
      </table>
      <ErrorBox error={err} />
      <div className="form-actions">
        <button className="btn primary" disabled={!total} onClick={async () => {
          setErr(null);
          try {
            await rpc('post_opening_balances', { entry_date: d, balances: Object.entries(amts).map(([fund_id, amount]) => ({ fund_id, amount: num(amount) })) });
            toast('Opening balances posted'); setAmts({}); refresh();
          } catch (e: any) { setErr(e.message); }
        }}>Post opening balances</button>
        <span className="muted small">Posted as a journal entry you can void from Transfers & adjustments if needed.</span>
      </div>
    </Card>
  );
}

function Close() {
  const { lookups, refresh, toast } = useApp();
  const current = lookups?.settings?.closed_through ?? null;
  const lastMonthEnd = (() => { const n = new Date(); return new Date(n.getFullYear(), n.getMonth(), 0).toISOString().slice(0, 10); })();
  const [d, setD] = useState<string>(lastMonthEnd);
  return (
    <Card title="Close the books">
      <p>Closing a period locks it: nothing can be entered, changed or voided on or before that date. Close each month after you have reconciled the bank statement and printed missionary statements, and close the year after your CPA's review.</p>
      <p><strong>Currently closed through:</strong> {current ? date(current) : 'Nothing is closed yet'}</p>
      <div className="form-grid">
        <Field label="Close through"><input type="date" value={d} onChange={(e) => setD(e.target.value)} /></Field>
      </div>
      <div className="form-actions">
        <button className="btn primary" onClick={async () => { await rpc('set_closed_through', { closed_through: d }); refresh(); toast(`Books closed through ${date(d)}`); }}>Close through {date(d)}</button>
        {current && <button className="btn danger-outline" onClick={async () => {
          if (!confirm('Reopen all closed periods? Only do this to correct a mistake. The change is recorded in the change log.')) return;
          await rpc('set_closed_through', { closed_through: null }); refresh(); toast('All periods reopened');
        }}>Reopen</button>}
      </div>
    </Card>
  );
}

function Accounts() {
  const { lookups, refresh, toast } = useApp();
  const [edit, setEdit] = useState<Partial<Account> | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const accounts = lookups?.accounts ?? [];
  const TYPES: [string, string][] = [['asset', 'Assets'], ['liability', 'Liabilities'], ['net_assets', 'Net assets & interfund'], ['revenue', 'Revenue'], ['expense', 'Expenses']];
  return (
    <Card title="Chart of accounts" actions={<button className="btn small" onClick={() => setEdit({ type: 'expense', functional_class: 'management_general' })}>+ New account</button>}>
      <p className="muted small">Accounts describe <em>what</em> money is (cash, a gift, travel). Funds describe <em>whose</em> it is. System accounts can be renamed but not removed.</p>
      <table className="table compact">
        {TYPES.map(([t, label]) => (
          <tbody key={t}>
            <tr className="group-row"><td colSpan={4}>{label}</td></tr>
            {accounts.filter((a) => a.type === t).map((a) => (
              <tr key={a.id} className={`clickable ${a.active ? '' : 'void'}`} onClick={() => setEdit(a)}>
                <td className="muted">{a.code}</td><td>{a.name} {a.is_system && <Badge>system</Badge>}</td>
                <td className="small">{a.functional_class ? FUNCTIONAL[a.functional_class] : ''}{(a as any).tax_form && <Badge tone="info">{({ nec1: '1099-NEC', misc1: '1099-MISC rents', misc3: '1099-MISC other' } as any)[(a as any).tax_form]}</Badge>}</td><td className="small muted">{a.description}</td>
              </tr>
            ))}
          </tbody>
        ))}
      </table>
      {edit && (
        <Modal title={edit.id ? `Edit ${edit.code}` : 'New account'} onClose={() => { setEdit(null); setErr(null); }}
          footer={<><button className="btn" onClick={() => setEdit(null)}>Cancel</button><button className="btn primary" onClick={async () => {
            try { await rpc('save_account', edit); refresh(); setEdit(null); toast('Account saved'); } catch (e: any) { setErr(e.message); }
          }}>Save</button></>}>
          <div className="form-grid">
            <Field label="Number"><input value={edit.code ?? ''} disabled={edit.is_system} onChange={(e) => setEdit({ ...edit, code: e.target.value })} /></Field>
            <Field label="Name"><input value={edit.name ?? ''} onChange={(e) => setEdit({ ...edit, name: e.target.value })} /></Field>
            {!edit.id && (
              <Field label="Type"><select value={edit.type} onChange={(e) => setEdit({ ...edit, type: e.target.value })}>
                <option value="expense">Expense</option><option value="revenue">Revenue</option><option value="asset">Asset</option><option value="liability">Liability</option></select></Field>
            )}
            {edit.type === 'expense' && (
              <Field label="Default function"><select value={edit.functional_class ?? 'management_general'} onChange={(e) => setEdit({ ...edit, functional_class: e.target.value })}>
                {Object.entries(FUNCTIONAL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></Field>
            )}
            {edit.type === 'expense' && (
              <Field label="Reported on Form 1099" hint="Payments to 1099 payees charged here are added to this box.">
                <select value={(edit as any).tax_form ?? ''} onChange={(e) => setEdit({ ...edit, tax_form: e.target.value } as any)}>
                  <option value="">Not reported</option>
                  <option value="nec1">1099-NEC box 1, nonemployee compensation</option>
                  <option value="misc1">1099-MISC box 1, rents</option>
                  <option value="misc3">1099-MISC box 3, other income</option>
                </select>
              </Field>
            )}
            <Field label="Description" wide><input value={edit.description ?? ''} onChange={(e) => setEdit({ ...edit, description: e.target.value })} /></Field>
            {edit.id && !edit.is_system && <label className="check"><input type="checkbox" checked={edit.active !== false} onChange={(e) => setEdit({ ...edit, active: e.target.checked })} /> Active</label>}
          </div>
          <ErrorBox error={err} />
        </Modal>
      )}
    </Card>
  );
}

function Data() {
  const { refresh, toast } = useApp();
  const [busy, setBusy] = useState<string | null>(null);
  const run = async (label: string, fn: () => Promise<void>) => {
    setBusy(label);
    try { await fn(); } catch (e: any) { toast(e.message, 'error'); } finally { setBusy(null); }
  };
  const exportSql = () => run('export', async () => {
    const sql = await buildDataExportSql();
    download(`bem-ledger-data-${today()}.sql`, sql, 'application/sql');
    toast('Data exported');
  });
  return (
    <>
      <Card title="Back up / move your data">
        <p>Downloads every record as a SQL file. Keep it as a backup, or run it in the Supabase SQL Editor (after the migration files, on an empty database) to move your local data to the live system.</p>
        <button className="btn primary" disabled={!!busy} onClick={exportSql}>{busy === 'export' ? 'Exporting…' : 'Download data (.sql)'}</button>
      </Card>
      {MODE === 'local' && (
        <>
          <Card title="Restore from a backup">
            <p>Replaces <strong>everything</strong> in this local database with the contents of a backup file made above.</p>
            <input type="file" accept=".sql,text/plain" disabled={!!busy} onChange={(e) => {
              const f = e.target.files?.[0]; if (!f) return;
              if (!confirm(`Replace all local data with ${f.name}?`)) { e.target.value = ''; return; }
              run('restore', async () => { const text = await f.text(); await resetLocalDatabase(); await runLocalSql(text); await refresh(); toast('Backup restored'); window.location.hash = '#/dashboard'; });
            }} />
          </Card>
          <Card title="Test data">
            <p>The local database lives in this browser on this computer only. Clearing your browser's site data erases it, so download a backup before you rely on it.</p>
            <div className="form-actions">
              <button className="btn" disabled={!!busy} onClick={() => run('sample', async () => { await loadSampleData(); await refresh(); toast('Sample data loaded'); window.location.hash = '#/dashboard'; })}>
                {busy === 'sample' ? 'Loading…' : 'Load sample data'}</button>
              <button className="btn danger-outline" disabled={!!busy} onClick={() => {
                if (!confirm('Erase ALL data in this local database? This cannot be undone (unless you have a backup).')) return;
                run('reset', async () => { await resetLocalDatabase(); await refresh(); toast('Local database erased'); window.location.hash = '#/dashboard'; });
              }}>Erase everything</button>
            </div>
            <p className="muted small">Sample data uses BEM's real missionaries and photos with made-up donors and amounts. It can only be loaded into an empty ledger.</p>
          </Card>
        </>
      )}
    </>
  );
}

function Audit() {
  const { data } = useRpc<any[]>('list_audit_log', { limit: 300 });
  return (
    <Card title="Change log" actions={<span className="muted small">Postings are in the General Ledger; this log covers setup changes.</span>}>
      <table className="table compact">
        <thead><tr><th>When</th><th>Who</th><th>What</th></tr></thead>
        <tbody>{(data ?? []).map((a) => (
          <tr key={a.id}><td className="nowrap small">{new Date(a.at).toLocaleString()}</td><td className="small">{a.actor}</td>
            <td className="small">{a.action} {a.object}{a.detail?.name ? `: ${a.detail.name}` : a.detail?.display_name ? `: ${a.detail.display_name}` : ''}
              {a.action === 'set_closed_through' && `: ${a.detail?.from ?? 'open'} → ${a.detail?.to ?? 'open'}`}</td></tr>
        ))}</tbody>
      </table>
    </Card>
  );
}

export default function Settings({ sub = 'organization' }: { sub?: string }) {
  const C: Record<string, React.FC> = { organization: Organization, opening: Opening, close: Close, accounts: Accounts, data: Data, audit: Audit };
  const Comp = C[sub] ?? Organization;
  return (
    <div>
      <PageHeader title="Settings" />
      <div className="tabs no-print">
        {TABS.map(([k, label]) => <a key={k} href={`#/settings/${k}`} className={k === sub ? 'active' : ''}>{label}</a>)}
      </div>
      <Comp />
    </div>
  );
}
