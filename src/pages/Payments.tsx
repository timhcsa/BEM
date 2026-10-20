import React, { useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { FUNCTIONAL, PAY_METHODS, date, download, money, num, periods, toCsv, today, type Period } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, FundSelect, Loading, Modal, Money, MoneyInput, PageHeader, PeriodPicker, TAX_SHORT, TaxTreatmentSelect, VoidButton, defaultTaxTreatment } from '../components/ui';

type Line = { key: number; fund_id: string; account_id: string; functional_class: string; amount: string; memo: string; tax_treatment: string; taxTouched?: boolean };
let k = 1;
const newLine = (fund_id = '', account_id = ''): Line => ({ key: k++, fund_id, account_id, functional_class: '', amount: '', memo: '', tax_treatment: '' });

export function PaymentEntry({ onPosted }: { onPosted?: () => void }) {
  const { lookups, toast, refresh } = useApp();
  const funds = lookups?.funds ?? [];
  const expenseAccounts = (lookups?.accounts ?? []).filter((a) => a.type === 'expense' && a.active);
  const missionaries = (lookups?.missionaries ?? []).filter((m) => m.active);
  const payees = useRpc<string[]>('list_payee_names', {});
  const [d, setD] = useState({ disb_date: today(), payee_name: '', missionary_id: '', method: 'check', reference: '', memo: '' });
  const [lines, setLines] = useState<Line[]>([newLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [overdraft, setOverdraft] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const total = lines.reduce((s, l) => s + num(l.amount), 0);
  const update = (key: number, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const chooseMissionary = (id: string) => {
    const m = missionaries.find((x) => x.id === id);
    setD({ ...d, missionary_id: id, payee_name: m ? m.display_name : d.payee_name });
    if (m) setLines((ls) => ls.map((l, i) => (i === 0 ? { ...l, fund_id: m.fund_id, account_id: l.account_id || 'a0000000-0000-0000-0000-000000005000' } : l)));
  };
  const isMissionary = !!d.missionary_id;
  const treatmentOf = (l: Line) => l.tax_treatment || defaultTaxTreatment(expenseAccounts.find((a) => a.id === l.account_id) as any);
  const taxableTotal = lines.reduce((s, l) => s + (treatmentOf(l) === 'taxable' ? num(l.amount) : 0), 0);

  const post = async (allow = false) => {
    setBusy(true); setErr(null);
    try {
      const filled = lines.filter((l) => l.fund_id || l.account_id || num(l.amount));
      await rpc('post_disbursement', { ...d, allow_overdraft: allow,
        lines: filled.map((l) => ({ fund_id: l.fund_id, account_id: l.account_id, functional_class: l.functional_class, amount: num(l.amount), memo: l.memo,
          tax_treatment: isMissionary ? treatmentOf(l) : null })) });
      toast(d.disb_date > today()
        ? `Payment of ${money(total)} to ${d.payee_name} recorded, dated ${date(d.disb_date)}. It's already out of the fund's balance.`
        : `Payment of ${money(total)} to ${d.payee_name} recorded`);
      setD({ ...d, payee_name: '', missionary_id: '', reference: d.method === 'check' && /^\d+$/.test(d.reference) ? String(Number(d.reference) + 1) : '', memo: '' });
      setLines([newLine()]); setOverdraft(null); refresh(); payees.reload(); onPosted?.();
    } catch (e: any) {
      if (e.message.startsWith('OVERDRAFT')) setOverdraft(e.message.replace(/^OVERDRAFT:\s*/, ''));
      else setErr(e.message);
    } finally { setBusy(false); }
  };

  return (
    <Card title="Record a payment">
      <div className="form-grid">
        <Field label="Missionary (optional)" hint="Pick one to fill in the payee and fund">
          <select value={d.missionary_id} onChange={(e) => chooseMissionary(e.target.value)}>
            <option value="">— Not a missionary payment —</option>
            {missionaries.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}
          </select>
        </Field>
        <Field label="Paid to">
          <input list="payees" value={d.payee_name} onChange={(e) => setD({ ...d, payee_name: e.target.value })} />
          <datalist id="payees">{(payees.data ?? []).map((p) => <option key={p} value={p} />)}</datalist>
        </Field>
        <Field label="Date paid"><input type="date" value={d.disb_date} onChange={(e) => setD({ ...d, disb_date: e.target.value })} /></Field>
        <Field label="Paid by">
          <select value={d.method} onChange={(e) => setD({ ...d, method: e.target.value })}>
            {Object.entries(PAY_METHODS).map(([key, v]) => <option key={key} value={key}>{v}</option>)}
          </select>
        </Field>
        <Field label={d.method === 'check' ? 'Check number' : 'Reference'}><input value={d.reference} onChange={(e) => setD({ ...d, reference: e.target.value })} /></Field>
        <Field label="Memo"><input value={d.memo} onChange={(e) => setD({ ...d, memo: e.target.value })} placeholder="e.g. October support" /></Field>
      </div>
      <h3 className="section-label">Charge to</h3>
      <table className="table lines">
        <thead><tr><th>Fund</th><th>Expense category</th>{isMissionary && <th>Tax (W-2)</th>}<th>Function</th><th className="num">Amount</th><th>Line note</th><th /></tr></thead>
        <tbody>
          {lines.map((l) => {
            const acct = expenseAccounts.find((a) => a.id === l.account_id);
            const fund = funds.find((f) => f.id === l.fund_id);
            return (
              <tr key={l.key}>
                <td style={{ minWidth: 200 }}>
                  <FundSelect funds={funds} value={l.fund_id} onChange={(id) => update(l.key, { fund_id: id })} />
                  {fund && <div className="muted small">Balance {money(fund.balance)}</div>}
                </td>
                <td style={{ minWidth: 200 }}>
                  <select value={l.account_id} onChange={(e) => update(l.key, { account_id: e.target.value, functional_class: '', ...(l.taxTouched ? {} : { tax_treatment: '' }) })}>
                    <option value="">Choose…</option>
                    {expenseAccounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}
                  </select>
                </td>
                {isMissionary && (
                  <td style={{ minWidth: 230 }}>
                    <TaxTreatmentSelect value={treatmentOf(l)} onChange={(v) => update(l.key, { tax_treatment: v, taxTouched: true })} />
                    {treatmentOf(l) === 'reimbursement' && <div className="muted small">Receipts must be on file</div>}
                  </td>
                )}
                <td>
                  <select value={l.functional_class || acct?.functional_class || ''} onChange={(e) => update(l.key, { functional_class: e.target.value })}>
                    {Object.entries(FUNCTIONAL).map(([key, v]) => <option key={key} value={key}>{v}</option>)}
                  </select>
                </td>
                <td style={{ width: 140 }}><MoneyInput value={l.amount} onChange={(v) => update(l.key, { amount: v })} /></td>
                <td><input value={l.memo} onChange={(e) => update(l.key, { memo: e.target.value })} /></td>
                <td>{lines.length > 1 && <button className="icon-btn" aria-label="Remove line" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>×</button>}</td>
              </tr>
            );
          })}
        </tbody>
        <tfoot><tr>
          <td colSpan={isMissionary ? 4 : 3}><button className="btn small" onClick={() => setLines([...lines, newLine(lines[lines.length - 1]?.fund_id)])}>+ Add a line</button>
            {isMissionary && total > 0 && <span className="muted small tax-summary">W-2 wages: <strong>{money(taxableTotal)}</strong> · Not reported: {money(total - taxableTotal)}</span>}</td>
          <td className="num total-cell"><Money v={total} /></td><td colSpan={2} />
        </tr></tfoot>
      </table>
      <ErrorBox error={err} />
      <div className="form-actions">
        <button className="btn primary" disabled={busy} onClick={() => post(false)}>{busy ? 'Saving…' : 'Record payment'}</button>
      </div>
      {overdraft && (
        <Modal title="This would overdraw a fund" size="sm" onClose={() => setOverdraft(null)}
          footer={<><button className="btn" onClick={() => setOverdraft(null)}>Go back</button><button className="btn danger" onClick={() => post(true)}>Record anyway</button></>}>
          <p><strong>{overdraft}</strong></p>
          <p>A fund below zero means it is spending money that belongs to other funds. Usually you would wait for more gifts, or transfer money in from the General Fund first (with board approval).</p>
        </Modal>
      )}
    </Card>
  );
}

function PaymentDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { data: d, reload } = useRpc<any>('get_disbursement', { id });
  const { toast, refresh } = useApp();
  if (!d) return null;
  return (
    <Modal title={<>Payment #{d.disb_number} {d.status === 'void' && <Badge tone="bad">VOID</Badge>} {d.cleared && <Badge tone="good">cleared</Badge>}</>} onClose={onClose} size="lg"
      footer={<>
        {d.status === 'posted' && <VoidButton what="payment" disabled={d.cleared} disabledReason="Cleared on a completed bank reconciliation"
          onVoid={async (reason) => { await rpc('void_disbursement', { id, reason }); toast('Payment voided'); refresh(); reload(); onChanged(); }} />}
        <button className="btn" onClick={onClose}>Close</button>
      </>}>
      <dl className="dl">
        <dt>Paid to</dt><dd>{d.payee_name}</dd>
        <dt>Date</dt><dd>{date(d.disb_date)}</dd>
        <dt>Paid by</dt><dd>{PAY_METHODS[d.method]} {d.reference}</dd>
        <dt>Total</dt><dd><Money v={d.total} /></dd>
        {d.memo && <><dt>Memo</dt><dd>{d.memo}</dd></>}
        <dt>Entered</dt><dd className="muted">{new Date(d.created_at).toLocaleString()} by {d.created_by}</dd>
        {d.status === 'void' && <><dt>Voided</dt><dd>{d.void_reason}</dd></>}
      </dl>
      <table className="table">
        <thead><tr><th>Fund</th><th>Category</th><th>Tax (W-2)</th><th>Function</th><th className="num">Amount</th><th>Note</th></tr></thead>
        <tbody>{d.lines.map((l: any) => (
          <tr key={l.id}><td>{l.fund_name}</td><td>{l.account_code} · {l.account_name}</td>
            <td>{l.tax_treatment ? <Badge tone={l.tax_treatment === 'taxable' ? 'warn' : 'neutral'}>{TAX_SHORT[l.tax_treatment]}</Badge> : <span className="muted small">account default</span>}</td>
            <td>{FUNCTIONAL[l.functional_class]}</td>
            <td className="num"><Money v={l.amount} /></td><td>{l.memo}</td></tr>
        ))}</tbody>
      </table>
    </Modal>
  );
}

export default function Payments() {
  const { lookups } = useApp();
  const [period, setPeriod] = useState<Period>(periods().this_month);
  const [fundId, setFundId] = useState('');
  const params = useMemo(() => ({ from: period.from, to: period.to, fund_id: fundId }), [period, fundId]);
  const { data, loading, reload } = useRpc<any[]>('list_disbursements', params);
  const [open, setOpen] = useState<string | null>(null);
  const rows = data ?? [];
  const total = rows.filter((r) => r.status === 'posted').reduce((s, r) => s + Number(r.total), 0);
  return (
    <div>
      <PageHeader title="Payments" subtitle="Missionary support, reimbursements and ministry expenses paid from the bank."
        actions={<><a className="btn" href="#/recurring">Recurring payments</a><button className="btn" onClick={() => download(`payments-${period.from}-to-${period.to}.csv`, toCsv(rows, [
          ['disb_number', 'Payment #'], ['disb_date', 'Date'], ['payee_name', 'Payee'], ['method', 'Method'], ['reference', 'Reference'],
          ['funds', 'Funds'], ['categories', 'Categories'], ['total', 'Amount'], ['status', 'Status']]), 'text/csv')}>Export CSV</button></>} />
      <PaymentEntry onPosted={reload} />
      <div className="filters no-print">
        <PeriodPicker value={period} onChange={setPeriod} />
        <FundSelect funds={lookups?.funds ?? []} value={fundId} onChange={setFundId} includeInactive placeholder="All funds" />
      </div>
      <Card title="Payment register">
        {loading && !data ? <Loading /> : rows.length ? (
          <table className="table">
            <thead><tr><th>#</th><th>Date</th><th>Paid to</th><th>Fund</th><th>Category</th><th>Paid by</th><th className="num">Amount</th><th>Bank</th></tr></thead>
            <tbody>{rows.map((r) => (
              <tr key={r.id} className={`clickable ${r.status === 'void' ? 'void' : ''}`} onClick={() => setOpen(r.id)}>
                <td className="muted">{r.disb_number}</td><td className="nowrap">{date(r.disb_date)}{r.disb_date > today() && <div><Badge tone="info">future-dated</Badge></div>}</td><td>{r.payee_name}<div className="muted small">{r.memo}</div></td>
                <td className="small">{r.funds}</td><td className="small">{r.categories}</td><td className="small">{PAY_METHODS[r.method]} {r.reference}</td>
                <td className="num"><Money v={r.total} /></td>
                <td>{r.status === 'void' ? <Badge tone="bad">void</Badge> : r.cleared ? <Badge tone="good">cleared</Badge> : <Badge>uncleared</Badge>}</td>
              </tr>
            ))}</tbody>
            <tfoot><tr className="total"><td colSpan={6}>Total posted</td><td className="num"><Money v={total} /></td><td /></tr></tfoot>
          </table>
        ) : <Empty>No payments in this period.</Empty>}
      </Card>
      {open && <PaymentDetail id={open} onClose={() => setOpen(null)} onChanged={reload} />}
    </div>
  );
}
