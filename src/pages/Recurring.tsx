import React, { useEffect, useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { FUNCTIONAL, PAY_METHODS, date, money, num } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, FundSelect, Loading, Modal, Money, MoneyInput, PageHeader, TAX_SHORT, TaxTreatmentSelect, defaultTaxTreatment } from '../components/ui';

const thisMonth = () => new Date().toISOString().slice(0, 7);
const monthName = (ym: string) => { const [y, m] = ym.split('-').map(Number); return new Date(y, m - 1, 1).toLocaleDateString('en-US', { month: 'long', year: 'numeric' }); };
const addMonths = (ym: string, n: number) => { const [y, m] = ym.split('-').map(Number); const d = new Date(y, m - 1 + n, 1); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };

type Line = { key: number; fund_id: string; account_id: string; functional_class: string; amount: string; memo: string; tax_treatment: string; taxTouched?: boolean };
let k = 1;
const newLine = (fund_id = '', account_id = ''): Line => ({ key: k++, fund_id, account_id, functional_class: '', amount: '', memo: '', tax_treatment: '' });

function RecurringForm({ initial, onClose, onSaved }: { initial?: any; onClose: () => void; onSaved: () => void }) {
  const { lookups, toast } = useApp();
  const funds = lookups?.funds ?? [];
  const accounts = (lookups?.accounts ?? []).filter((a) => a.type === 'expense' && a.active);
  const missionaries = (lookups?.missionaries ?? []).filter((m) => m.active);
  const [r, setR] = useState<any>(initial ? { ...initial, start_month: String(initial.start_month).slice(0, 7), end_month: initial.end_month ? String(initial.end_month).slice(0, 7) : '' }
    : { method: 'ach', day_of_month: 25, start_month: thisMonth(), end_month: '', active: true, payee_name: '', missionary_id: '', name: '' });
  const [lines, setLines] = useState<Line[]>(initial?.lines?.map((l: any) => ({ key: k++, fund_id: l.fund_id, account_id: l.account_id, functional_class: l.functional_class ?? '', amount: String(l.amount), memo: l.memo ?? '', tax_treatment: l.tax_treatment ?? '', taxTouched: !!l.tax_treatment })) ?? [newLine()]);
  const [err, setErr] = useState<string | null>(null);
  const upd = (key: number, p: Partial<Line>) => setLines(lines.map((l) => (l.key === key ? { ...l, ...p } : l)));
  const total = lines.reduce((s, l) => s + num(l.amount), 0);
  const isMissionary = !!r.missionary_id;
  const treatmentOf = (l: Line) => l.tax_treatment || defaultTaxTreatment(accounts.find((a) => a.id === l.account_id) as any);
  const chooseMissionary = (id: string) => {
    const m = missionaries.find((x) => x.id === id);
    setR({ ...r, missionary_id: id, payee_name: m ? m.display_name : r.payee_name, name: r.name || (m ? `${m.display_name} - monthly support` : '') });
    if (m && !initial) setLines([{ ...newLine(m.fund_id, 'a0000000-0000-0000-0000-000000005000') }, { ...newLine(m.fund_id, 'a0000000-0000-0000-0000-000000005010') }]);
  };
  const save = async () => {
    setErr(null);
    try {
      await rpc('save_recurring', { ...r, lines: lines.filter((l) => l.fund_id || l.account_id || num(l.amount))
        .map((l) => ({ ...l, amount: num(l.amount), tax_treatment: isMissionary ? treatmentOf(l) : null })) });
      toast('Recurring payment saved'); onSaved();
    } catch (e: any) { setErr(e.message); }
  };
  return (
    <Modal title={initial ? `Edit: ${initial.name}` : 'New recurring payment'} onClose={onClose} size="lg"
      footer={<>
        {initial && <button className="btn danger-outline" style={{ marginRight: 'auto' }} onClick={async () => {
          if (!confirm('Remove this recurring payment? Payments already made stay in the books.')) return;
          const res = await rpc('delete_recurring', { id: initial.id });
          toast(res.deactivated ? 'Turned off (it has payment history, so it is kept)' : 'Removed'); onSaved();
        }}>Remove</button>}
        <button className="btn" onClick={onClose}>Cancel</button>
        <button className="btn primary" onClick={save}>Save</button>
      </>}>
      <div className="form-grid">
        <Field label="Missionary (optional)" hint="Fills in the payee and their fund">
          <select value={r.missionary_id ?? ''} onChange={(e) => chooseMissionary(e.target.value)}>
            <option value="">— Not a missionary —</option>
            {missionaries.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}
          </select>
        </Field>
        <Field label="Paid to"><input value={r.payee_name} onChange={(e) => setR({ ...r, payee_name: e.target.value })} /></Field>
        <Field label="Name for this setup"><input value={r.name} onChange={(e) => setR({ ...r, name: e.target.value })} placeholder="e.g. Monthly support" /></Field>
        <Field label="Paid by">
          <select value={r.method} onChange={(e) => setR({ ...r, method: e.target.value })}>
            {Object.entries(PAY_METHODS).filter(([key]) => key !== 'bank_fee').map(([key, v]) => <option key={key} value={key}>{v}</option>)}
          </select>
        </Field>
        <Field label="Day of the month" hint="1–28"><input type="number" min={1} max={28} value={r.day_of_month} onChange={(e) => setR({ ...r, day_of_month: e.target.value })} /></Field>
        <Field label="First month"><input type="month" value={r.start_month} onChange={(e) => setR({ ...r, start_month: e.target.value })} /></Field>
        <Field label="Last month (optional)" hint="Leave blank to continue until turned off"><input type="month" value={r.end_month ?? ''} onChange={(e) => setR({ ...r, end_month: e.target.value })} /></Field>
        <Field label="Memo on each payment"><input value={r.memo ?? ''} onChange={(e) => setR({ ...r, memo: e.target.value })} placeholder="e.g. Monthly support" /></Field>
        {initial && <label className="check"><input type="checkbox" checked={r.active} onChange={(e) => setR({ ...r, active: e.target.checked })} /> Active (shows up each month)</label>}
      </div>
      <h3 className="section-label">Each month, pay</h3>
      <table className="table lines">
        <thead><tr><th>Fund</th><th>Category</th>{isMissionary && <th>Tax (1099)</th>}<th>Function</th><th className="num">Amount</th><th /></tr></thead>
        <tbody>{lines.map((l) => {
          const a = accounts.find((x) => x.id === l.account_id);
          return (
            <tr key={l.key}>
              <td style={{ minWidth: 190 }}><FundSelect funds={funds} value={l.fund_id} onChange={(v) => upd(l.key, { fund_id: v })} /></td>
              <td style={{ minWidth: 220 }}><select value={l.account_id} onChange={(e) => upd(l.key, { account_id: e.target.value, functional_class: '', ...(l.taxTouched ? {} : { tax_treatment: '' }) })}>
                <option value="">Choose…</option>{accounts.map((x) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}</select></td>
              {isMissionary && <td style={{ minWidth: 220 }}><TaxTreatmentSelect value={treatmentOf(l)} onChange={(v) => upd(l.key, { tax_treatment: v, taxTouched: true })} /></td>}
              <td><select value={l.functional_class || a?.functional_class || 'program'} onChange={(e) => upd(l.key, { functional_class: e.target.value })}>
                {Object.entries(FUNCTIONAL).map(([key, v]) => <option key={key} value={key}>{v}</option>)}</select></td>
              <td style={{ width: 140 }}><MoneyInput value={l.amount} onChange={(v) => upd(l.key, { amount: v })} /></td>
              <td>{lines.length > 1 && <button className="icon-btn" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>×</button>}</td>
            </tr>
          );
        })}</tbody>
        <tfoot><tr><td colSpan={isMissionary ? 4 : 3}><button className="btn small" onClick={() => setLines([...lines, newLine(lines[0]?.fund_id)])}>+ Add a line</button></td>
          <td className="num total-cell"><Money v={total} /></td><td /></tr></tfoot>
      </table>
      <p className="muted small">Tip for ministers: put the board-designated housing allowance on its own line (5010) so it's tracked separately from salary for the year-end 1099 or W-2.</p>
      <ErrorBox error={err} />
    </Modal>
  );
}

export default function Recurring() {
  const { toast, refresh } = useApp();
  const [period, setPeriod] = useState(thisMonth());
  const due = useRpc<any>('recurring_due', { period });
  const all = useRpc<any[]>('list_recurring', {});
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [dates, setDates] = useState<Record<string, string>>({});
  const [refs, setRefs] = useState<Record<string, string>>({});
  const [editing, setEditing] = useState<any | null>(null);
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<any[] | null>(null);
  const [overdraft, setOverdraft] = useState<string[] | null>(null);

  const items: any[] = due.data?.items ?? [];
  const open = items.filter((i) => !i.posted);
  useEffect(() => {
    setSel(new Set(open.map((i) => i.id)));
    setDates(Object.fromEntries(open.map((i) => [i.id, i.due_date])));
    setRefs({});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [due.data]);

  const selected = open.filter((i) => sel.has(i.id));
  const total = selected.reduce((s, i) => s + Number(i.total), 0);
  // overdraft warning: what the selected payments take out of each fund
  const shortfalls = useMemo(() => {
    const need: Record<string, { name: string; bal: number; amt: number }> = {};
    selected.forEach((i) => i.lines.forEach((l: any) => {
      need[l.fund_id] ??= { name: l.fund_name, bal: Number(l.fund_balance), amt: 0 };
      need[l.fund_id].amt += Number(l.amount);
    }));
    return Object.values(need).filter((n) => n.bal - n.amt < 0);
  }, [selected]);

  const post = async (ids: string[], allow: boolean) => {
    setBusy(true); setResults(null);
    try {
      const res = await rpc('post_recurring', { period, allow_overdraft: allow,
        items: ids.map((id) => ({ id, date: dates[id], reference: refs[id] })) });
      const over = res.results.filter((r: any) => !r.ok && String(r.message).startsWith('OVERDRAFT')).map((r: any) => r.id);
      setResults(res.results.filter((r: any) => !(over.includes(r.id) && !allow)));
      if (over.length && !allow) setOverdraft(over);
      if (res.posted) { toast(`${res.posted} payment${res.posted === 1 ? '' : 's'} posted`); refresh(); }
      due.reload(); all.reload();
    } catch (e: any) { toast(e.message, 'error'); } finally { setBusy(false); }
  };

  return (
    <div>
      <PageHeader title="Recurring payments" subtitle="Monthly salary, support and other regular payments. Set each one up once; every month, review what's due and post it in one step."
        actions={<button className="btn primary" onClick={() => setEditing({})}>+ New recurring payment</button>} />

      <Card title={<span className="month-nav">
          <button className="icon-btn" aria-label="Previous month" onClick={() => setPeriod(addMonths(period, -1))}>‹</button>
          Due for {monthName(period)}
          <button className="icon-btn" aria-label="Next month" onClick={() => setPeriod(addMonths(period, 1))}>›</button>
        </span>}
        actions={<input type="month" value={period} onChange={(e) => e.target.value && setPeriod(e.target.value)} />}>
        {due.loading && !due.data ? <Loading /> : items.length ? (
          <>
            <table className="table">
              <thead><tr>
                <th><input type="checkbox" aria-label="Select all" checked={open.length > 0 && sel.size === open.length} onChange={(e) => setSel(e.target.checked ? new Set(open.map((i) => i.id)) : new Set())} /></th>
                <th>Payment</th><th>Charged to</th><th>Date</th><th>Check / ref #</th><th className="num">Amount</th><th>Status</th></tr></thead>
              <tbody>{items.map((i) => (
                <tr key={i.id} className={i.posted ? 'done-row' : ''}>
                  <td>{!i.posted && <input type="checkbox" checked={sel.has(i.id)} onChange={() => { const s = new Set(sel); s.has(i.id) ? s.delete(i.id) : s.add(i.id); setSel(s); }} />}</td>
                  <td><strong>{i.payee_name}</strong><div className="muted small">{i.name} · {PAY_METHODS[i.method]}</div></td>
                  <td className="small">{i.lines.map((l: any) => <div key={l.id}>{l.fund_name}: {l.account_name} {money(l.amount)}{l.tax_treatment && <span className="muted"> · {TAX_SHORT[l.tax_treatment]}</span>}</div>)}</td>
                  <td style={{ width: 160 }}>{i.posted ? date(i.posted_disbursement.date) : <input type="date" value={dates[i.id] ?? i.due_date} onChange={(e) => setDates({ ...dates, [i.id]: e.target.value })} />}</td>
                  <td style={{ width: 120 }}>{!i.posted && i.method === 'check' && <input value={refs[i.id] ?? ''} placeholder="Check #" onChange={(e) => setRefs({ ...refs, [i.id]: e.target.value })} />}</td>
                  <td className="num"><Money v={i.total} /></td>
                  <td>{i.posted ? <Badge tone="good">Posted · #{i.posted_disbursement.disb_number}</Badge> : <Badge tone="warn">Due {date(i.due_date)}</Badge>}</td>
                </tr>
              ))}</tbody>
              <tfoot><tr className="total"><td colSpan={5}>{selected.length} selected</td><td className="num"><Money v={total} /></td><td /></tr></tfoot>
            </table>
            {shortfalls.length > 0 && (
              <div className="warn-box">
                <strong>Not enough in:</strong> {shortfalls.map((s) => `${s.name} (balance ${money(s.bal)}, needs ${money(s.amt)})`).join('; ')}.
                {' '}Those payments will ask before overdrawing the fund.
              </div>
            )}
            <div className="form-actions">
              <button className="btn primary" disabled={busy || !selected.length} onClick={() => post(selected.map((i) => i.id), false)}>
                {busy ? 'Posting…' : `Post ${selected.length} payment${selected.length === 1 ? '' : 's'} (${money(total)})`}</button>
              {open.length === 0 && <span className="muted">Everything for {monthName(period)} has been posted. ✓</span>}
            </div>
            {results && results.length > 0 && (
              <div className="results">
                {results.map((r) => <div key={r.id} className={r.ok ? 'ok' : 'bad'}>{r.ok ? '✓' : '✗'} {r.name}{r.ok ? ` — payment #${r.disb_number}, ${money(r.total)}` : ` — ${r.message}`}</div>)}
              </div>
            )}
          </>
        ) : <Empty>Nothing is set up to be paid in {monthName(period)}.</Empty>}
      </Card>

      <Card title="Recurring payment setups">
        {all.data?.length ? (
          <table className="table">
            <thead><tr><th>Payment</th><th>Charged to</th><th>Schedule</th><th className="num">Monthly</th><th>Recent</th></tr></thead>
            <tbody>{all.data.map((r) => (
              <tr key={r.id} className={`clickable ${r.active ? '' : 'void'}`} onClick={() => setEditing(r)}>
                <td><strong>{r.name}</strong><div className="muted small">{r.payee_name} · {PAY_METHODS[r.method]}</div></td>
                <td className="small">{r.lines.map((l: any) => <div key={l.id}>{l.fund_name}: {l.account_name} {money(l.amount)}</div>)}</td>
                <td className="small">Day {r.day_of_month} · from {monthName(String(r.start_month).slice(0, 7))}{r.end_month ? ` to ${monthName(String(r.end_month).slice(0, 7))}` : ''}
                  {!r.active && <> <Badge>off</Badge></>}</td>
                <td className="num"><Money v={r.total} /></td>
                <td className="small">{r.history.length ? r.history.slice(0, 3).map((h: any) => <div key={h.disbursement_id}>{h.period} #{h.disb_number} {h.status === 'void' ? '(void)' : ''}</div>) : <span className="muted">none yet</span>}</td>
              </tr>
            ))}</tbody>
            <tfoot><tr className="total"><td colSpan={3}>Total each month (active)</td><td className="num"><Money v={all.data.filter((r) => r.active).reduce((s, r) => s + Number(r.total), 0)} /></td><td /></tr></tfoot>
          </table>
        ) : <Empty>No recurring payments yet. Click “New recurring payment” to set up a missionary's monthly support.</Empty>}
      </Card>

      {editing && <RecurringForm initial={editing.id ? editing : undefined} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); all.reload(); due.reload(); }} />}
      {overdraft && (
        <Modal title="Some funds don't have enough" size="sm" onClose={() => setOverdraft(null)}
          footer={<><button className="btn" onClick={() => setOverdraft(null)}>Skip those</button>
            <button className="btn danger" onClick={() => { const ids = overdraft; setOverdraft(null); post(ids, true); }}>Pay anyway</button></>}>
          <p>{overdraft.length} payment{overdraft.length === 1 ? '' : 's'} would take a fund below zero, so {overdraft.length === 1 ? 'it was' : 'they were'} not posted:</p>
          <ul>{overdraft.map((id) => <li key={id}>{items.find((i) => i.id === id)?.name}</li>)}</ul>
          <p className="muted small">A fund below zero is spending money that belongs to other funds. Usually you would wait for gifts or transfer from the General Fund (with board approval) first.</p>
        </Modal>
      )}
    </div>
  );
}
