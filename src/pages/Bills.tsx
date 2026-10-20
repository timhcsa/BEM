import React, { useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { routeQuery, useApp, useRpc } from '../lib/store';
import { FUNCTIONAL, date, money, num, today } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, FundSelect, Loading, Modal, Money, MoneyInput, PageHeader, TAX_SHORT, TaxTreatmentSelect, VoidButton, defaultTaxTreatment } from '../components/ui';

type Line = { key: number; expense_date: string; account_id: string; fund_id: string; functional_class: string; tax_treatment: string;
  taxTouched?: boolean; quantity: string; amount: string; memo: string };
let k = 1;
const newLine = (fund_id = '', expense_date = ''): Line => ({ key: k++, expense_date, account_id: '', fund_id, functional_class: '', tax_treatment: '', quantity: '', amount: '', memo: '' });

const GENERAL = 'f0000000-0000-0000-0000-000000000001';
const PAY_LABEL: Record<string, string> = { check: 'Check', ach: 'EFT / ACH', debit_card: 'Debit card', wire: 'Wire', other: 'Other' };

/** Enter a missionary's expense report or a vendor bill. Nothing leaves the bank until it is paid. */
function BillEntry({ onPosted }: { onPosted: () => void }) {
  const { lookups, toast, refresh } = useApp();
  const funds = lookups?.funds ?? [];
  const accounts = (lookups?.accounts ?? []).filter((a: any) => a.type === 'expense' && a.active);
  const missionaries = (lookups?.missionaries ?? []).filter((m) => m.active);
  const rate = Number(lookups?.settings?.mileage_rate ?? 0.76);
  const [kind, setKind] = useState<'expense_report' | 'bill'>('expense_report');
  const [h, setH] = useState({ missionary_id: '', payee_name: '', bill_date: today(), due_date: '', reference: '', memo: '' });
  const [lines, setLines] = useState<Line[]>([newLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const missionary = missionaries.find((m) => m.id === h.missionary_id);
  const mFund = funds.find((f) => f.id === missionary?.fund_id);
  const acct = (id: string) => accounts.find((a) => a.id === id) as any;
  const treatmentOf = (l: Line) => l.tax_treatment || (l.account_id ? defaultTaxTreatment(acct(l.account_id)) : 'reimbursement');
  const upd = (key: number, p: Partial<Line>) => setLines((ls) => ls.map((l) => {
    if (l.key !== key) return l;
    const n = { ...l, ...p };
    const a = acct(n.account_id);
    if (a?.per_mile && ('quantity' in p || 'account_id' in p)) n.amount = n.quantity ? (Math.round(num(n.quantity) * rate * 100) / 100).toFixed(2) : n.amount;
    if ('account_id' in p && !l.taxTouched) n.tax_treatment = '';
    return n;
  }));
  const total = lines.reduce((s, l) => s + num(l.amount), 0);
  const reimb = accounts.filter((a: any) => a.reimbursable);
  const others = accounts.filter((a: any) => !a.reimbursable);

  const switchKind = (k2: 'expense_report' | 'bill') => {
    setKind(k2);
    setH({ ...h, missionary_id: '', payee_name: '' });
    setLines([newLine(k2 === 'bill' ? GENERAL : '')]);
  };
  const chooseMissionary = (id: string) => {
    const m = missionaries.find((x) => x.id === id);
    setH({ ...h, missionary_id: id, payee_name: m?.display_name ?? '' });
    setLines((ls) => ls.map((l) => ({ ...l, fund_id: m?.fund_id ?? l.fund_id })));
  };

  const save = async () => {
    setErr(null); setBusy(true);
    try {
      const filled = lines.filter((l) => l.account_id || num(l.amount));
      const b = await rpc('post_bill', {
        kind, ...h, missionary_id: kind === 'expense_report' ? h.missionary_id : null,
        lines: filled.map((l) => ({ fund_id: l.fund_id, account_id: l.account_id, functional_class: l.functional_class,
          tax_treatment: kind === 'expense_report' ? treatmentOf(l) : null, amount: num(l.amount),
          quantity: acct(l.account_id)?.per_mile && l.quantity ? num(l.quantity) : null, rate: acct(l.account_id)?.per_mile ? rate : null,
          expense_date: l.expense_date || null, memo: l.memo })),
      });
      toast(`${kind === 'expense_report' ? 'Expense report' : 'Bill'} #${b.bill_number} saved, ${money(b.total)} to pay`);
      setH({ ...h, reference: '', memo: '', due_date: '' });
      setLines([newLine(kind === 'bill' ? GENERAL : missionary?.fund_id ?? '')]);
      refresh(); onPosted();
    } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };

  return (
    <Card title={<span className="seg">
      <button className={kind === 'expense_report' ? 'on' : ''} onClick={() => switchKind('expense_report')}>Missionary expense report</button>
      <button className={kind === 'bill' ? 'on' : ''} onClick={() => switchKind('bill')}>Bill to pay</button>
    </span>}>
      <p className="muted small">
        {kind === 'expense_report'
          ? 'Reimbursements come out of the missionary’s own account. If the account doesn’t have enough yet, the report waits under “To pay” until more donations come in.'
          : 'A bill from a vendor (insurance, postage, printing…). Usually charged to the General Fund. Pay it now or later below.'}
      </p>
      <div className="form-grid">
        {kind === 'expense_report' ? (
          <Field label="Missionary">
            <select value={h.missionary_id} onChange={(e) => chooseMissionary(e.target.value)}>
              <option value="">Choose…</option>
              {missionaries.map((m) => <option key={m.id} value={m.id}>{m.display_name}</option>)}
            </select>
            {mFund && <span className="hint">Account balance {money(mFund.balance)}</span>}
          </Field>
        ) : (
          <Field label="Vendor / payee"><input value={h.payee_name} onChange={(e) => setH({ ...h, payee_name: e.target.value })} placeholder="e.g. Brotherhood Mutual" /></Field>
        )}
        <Field label={kind === 'expense_report' ? 'Report date' : 'Bill date'}><input type="date" value={h.bill_date} onChange={(e) => setH({ ...h, bill_date: e.target.value })} /></Field>
        {kind === 'bill' && <Field label="Due date"><input type="date" value={h.due_date} onChange={(e) => setH({ ...h, due_date: e.target.value })} /></Field>}
        <Field label={kind === 'expense_report' ? 'Report name / period' : 'Invoice #'}><input value={h.reference} onChange={(e) => setH({ ...h, reference: e.target.value })} placeholder={kind === 'expense_report' ? 'e.g. October trips' : ''} /></Field>
        <Field label="Note"><input value={h.memo} onChange={(e) => setH({ ...h, memo: e.target.value })} /></Field>
      </div>

      <table className="table lines">
        <thead><tr>
          {kind === 'expense_report' && <th>Date</th>}
          <th>Category</th><th>Fund</th>{kind === 'expense_report' && <th>Tax</th>}<th>Function</th><th>Miles</th><th className="num">Amount</th><th>Description</th><th />
        </tr></thead>
        <tbody>{lines.map((l) => {
          const a = acct(l.account_id);
          return (
            <tr key={l.key}>
              {kind === 'expense_report' && <td style={{ width: 140 }}><input type="date" value={l.expense_date} onChange={(e) => upd(l.key, { expense_date: e.target.value })} /></td>}
              <td style={{ minWidth: 200 }}>
                <select value={l.account_id} onChange={(e) => upd(l.key, { account_id: e.target.value, functional_class: '' })}>
                  <option value="">Choose…</option>
                  <optgroup label={kind === 'expense_report' ? 'Expense report categories' : 'Common'}>
                    {(kind === 'expense_report' ? reimb : others).map((x: any) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}
                  </optgroup>
                  <optgroup label="All other categories">
                    {(kind === 'expense_report' ? others : reimb).map((x: any) => <option key={x.id} value={x.id}>{x.code} · {x.name}</option>)}
                  </optgroup>
                </select>
              </td>
              <td style={{ minWidth: 170 }}><FundSelect funds={funds} value={l.fund_id} onChange={(v) => upd(l.key, { fund_id: v })} /></td>
              {kind === 'expense_report' && (
                <td style={{ minWidth: 190 }}><TaxTreatmentSelect value={treatmentOf(l)} onChange={(v) => upd(l.key, { tax_treatment: v, taxTouched: true })} />
                  {a?.code === '5040' && <div className="muted small">Non-taxable only under a QSEHRA/ICHRA</div>}</td>
              )}
              <td><select value={l.functional_class || a?.functional_class || 'program'} onChange={(e) => upd(l.key, { functional_class: e.target.value })}>
                {Object.entries(FUNCTIONAL).map(([kk, v]) => <option key={kk} value={kk}>{v}</option>)}</select></td>
              <td style={{ width: 110 }}>{a?.per_mile
                ? <><input inputMode="decimal" value={l.quantity} placeholder="miles" onChange={(e) => upd(l.key, { quantity: e.target.value.replace(/[^0-9.]/g, '') })} />
                    <div className="muted small">× {money(rate)}/mi</div></>
                : <span className="muted small">—</span>}</td>
              <td style={{ width: 130 }}><MoneyInput value={l.amount} onChange={(v) => upd(l.key, { amount: v })} /></td>
              <td><input value={l.memo} onChange={(e) => upd(l.key, { memo: e.target.value })} placeholder={a?.per_mile ? 'From – to, purpose' : ''} /></td>
              <td>{lines.length > 1 && <button className="icon-btn" aria-label="Remove line" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>×</button>}</td>
            </tr>
          );
        })}</tbody>
        <tfoot><tr>
          <td colSpan={kind === 'expense_report' ? 6 : 4}><button className="btn small" onClick={() => setLines([...lines, newLine(lines[lines.length - 1]?.fund_id, lines[lines.length - 1]?.expense_date)])}>+ Add a line</button></td>
          <td className="num total-cell"><Money v={total} /></td><td colSpan={2} />
        </tr></tfoot>
      </table>
      <ErrorBox error={err} />
      <div className="form-actions">
        <button className="btn primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : kind === 'expense_report' ? 'Save expense report' : 'Save bill'}</button>
        <span className="muted small">The expense is recorded now; the money leaves the bank when you pay it below.</span>
      </div>
    </Card>
  );
}

function BillDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { data: b, reload } = useRpc<any>('get_bill', { id });
  const { toast, refresh } = useApp();
  if (!b) return null;
  return (
    <Modal title={<>{b.kind === 'expense_report' ? 'Expense report' : 'Bill'} #{b.bill_number} <Badge tone={b.status === 'open' ? 'warn' : b.status === 'paid' ? 'good' : 'bad'}>{b.status === 'open' ? 'to pay' : b.status}</Badge></>}
      onClose={onClose} size="lg"
      footer={<>
        {b.status === 'open' && <VoidButton what={b.kind === 'expense_report' ? 'report' : 'bill'} onVoid={async (reason) => { await rpc('void_bill', { id, reason }); toast('Voided'); refresh(); reload(); onChanged(); }} />}
        <button className="btn" onClick={() => window.print()}>Print</button>
        <button className="btn" onClick={onClose}>Close</button>
      </>}>
      <dl className="dl">
        <dt>From</dt><dd>{b.payee_name}</dd>
        <dt>Date</dt><dd>{date(b.bill_date)}{b.due_date ? ` · due ${date(b.due_date)}` : ''}</dd>
        {b.reference && <><dt>{b.kind === 'expense_report' ? 'Report' : 'Invoice #'}</dt><dd>{b.reference}</dd></>}
        {b.memo && <><dt>Note</dt><dd>{b.memo}</dd></>}
        <dt>Total</dt><dd><Money v={b.total} /></dd>
        {b.payment && <><dt>Paid</dt><dd>{date(b.payment.pay_date)} by {PAY_LABEL[b.payment.method]}{b.payment.reference ? ` #${b.payment.reference}` : ''} (payment #{b.payment.payment_number})</dd></>}
        {b.status === 'void' && <><dt>Voided</dt><dd>{b.void_reason}</dd></>}
        <dt>Entered</dt><dd className="muted">{new Date(b.created_at).toLocaleString()} by {b.created_by}</dd>
      </dl>
      <table className="table compact">
        <thead><tr><th>Date</th><th>Category</th><th>Fund</th><th>Tax</th><th>Miles</th><th className="num">Amount</th><th>Description</th></tr></thead>
        <tbody>{b.lines.map((l: any) => (
          <tr key={l.id}><td>{date(l.expense_date)}</td><td>{l.account_name}</td><td>{l.fund_name}</td>
            <td className="small">{l.tax_treatment ? TAX_SHORT[l.tax_treatment] : '—'}</td>
            <td className="small">{l.quantity ? `${l.quantity} × ${money(l.rate)}` : ''}</td>
            <td className="num"><Money v={l.amount} /></td><td>{l.memo}</td></tr>
        ))}</tbody>
      </table>
    </Modal>
  );
}

/** Unpaid bills grouped by payee, each group paid with one check or EFT. */
function ToPay({ bills, onPaid, onOpen }: { bills: any[]; onPaid: () => void; onOpen: (id: string) => void }) {
  const { toast, refresh } = useApp();
  const groups = useMemo(() => {
    const m = new Map<string, any[]>();
    bills.forEach((b) => { const key = b.payee_id ?? b.payee_name; m.set(key, [...(m.get(key) ?? []), b]); });
    return [...m.entries()];
  }, [bills]);
  const [sel, setSel] = useState<Record<string, boolean>>({});
  const [pay, setPay] = useState<Record<string, { date: string; method: string; reference: string }>>({});
  const [err, setErr] = useState<Record<string, string | null>>({});
  const [over, setOver] = useState<{ key: string; msg: string } | null>(null);

  const doPay = async (key: string, list: any[], allow = false) => {
    const chosen = list.filter((b) => sel[b.id] !== false);
    const p = pay[key] ?? { date: today(), method: 'check', reference: '' };
    setErr({ ...err, [key]: null });
    try {
      const r = await rpc('pay_bills', { pay_date: p.date, method: p.method, reference: p.reference, bill_ids: chosen.map((b) => b.id), allow_overdraft: allow });
      toast(`Paid ${money(r.total)} to ${r.payee_name}${r.reference ? ` (${PAY_LABEL[r.method]} #${r.reference})` : ''}`);
      refresh(); onPaid();
    } catch (e: any) {
      if (e.message.startsWith('OVERDRAFT')) setOver({ key, msg: e.message.replace(/^OVERDRAFT:\s*/, '') });
      else setErr({ ...err, [key]: e.message });
    }
  };

  if (!groups.length) return <Empty>Nothing waiting to be paid.</Empty>;
  return (
    <div className="pay-groups">
      {groups.map(([key, list]) => {
        const chosen = list.filter((b) => sel[b.id] !== false);
        const total = chosen.reduce((s, b) => s + Number(b.total), 0);
        const p = pay[key] ?? { date: today(), method: 'check', reference: '' };
        const waiting = chosen.some((b) => b.missionary_fund && !b.can_pay);
        return (
          <div key={key} className={`pay-group ${waiting ? 'waiting' : ''}`}>
            <div className="pay-head">
              <strong>{list[0].payee_name}</strong>
              {waiting ? <Badge tone="warn">Waiting for donations</Badge> : null}
            </div>
            <table className="table compact">
              <tbody>{list.map((b) => (
                <tr key={b.id}>
                  <td style={{ width: 28 }}><input type="checkbox" checked={sel[b.id] !== false} onChange={(e) => setSel({ ...sel, [b.id]: e.target.checked })} /></td>
                  <td><button className="linklike" onClick={() => onOpen(b.id)}>{b.kind === 'expense_report' ? 'Expense report' : 'Bill'} #{b.bill_number}</button>
                    <div className="muted small">{date(b.bill_date)}{b.reference ? ` · ${b.reference}` : ''}{b.due_date ? ` · due ${date(b.due_date)}` : ''}</div></td>
                  <td className="small">{b.categories}<div className="muted">{b.funds}</div></td>
                  <td className="small">{!b.can_pay && b.short ? <span className="warn-text">{b.short}</span> : null}</td>
                  <td className="num"><Money v={b.total} /></td>
                </tr>
              ))}</tbody>
            </table>
            <div className="pay-bar">
              <Field label="Paid on"><input type="date" value={p.date} onChange={(e) => setPay({ ...pay, [key]: { ...p, date: e.target.value } })} /></Field>
              <Field label="Paid by">
                <select value={p.method} onChange={(e) => setPay({ ...pay, [key]: { ...p, method: e.target.value } })}>
                  {Object.entries(PAY_LABEL).map(([kk, v]) => <option key={kk} value={kk}>{v}</option>)}
                </select>
              </Field>
              <Field label={p.method === 'check' ? 'Check #' : 'EFT confirmation #'}><input value={p.reference} onChange={(e) => setPay({ ...pay, [key]: { ...p, reference: e.target.value } })} /></Field>
              <button className="btn primary" disabled={!chosen.length || waiting} onClick={() => doPay(key, list)}>Pay {money(total)}</button>
            </div>
            {waiting && <p className="muted small">The missionary’s account doesn’t have enough yet. This stays here and can be paid once more donations come in.</p>}
            <ErrorBox error={err[key] ?? null} />
          </div>
        );
      })}
      {over && (
        <Modal title="This would overdraw a fund" size="sm" onClose={() => setOver(null)}
          footer={<><button className="btn" onClick={() => setOver(null)}>Go back</button>
            <button className="btn danger" onClick={() => { const g = groups.find(([kk]) => kk === over.key); setOver(null); if (g) doPay(g[0], g[1], true); }}>Pay anyway</button></>}>
          <p><strong>{over.msg}</strong></p>
        </Modal>
      )}
    </div>
  );
}

export default function Bills() {
  const { toast, refresh } = useApp();
  const open = useRpc<any[]>('list_bills', { status: 'open' });
  const recent = useRpc<any[]>('list_bills', {});
  const payments = useRpc<any[]>('list_bill_payments', { limit: 100 });
  const [detail, setDetail] = useState<string | null>(routeQuery().get('open'));
  const reloadAll = () => { open.reload(); recent.reload(); payments.reload(); };
  const unpaid = (open.data ?? []).reduce((s, b) => s + Number(b.total), 0);
  return (
    <div>
      <PageHeader title="Bills & expense reports"
        subtitle="Enter missionary expense reports and vendor bills when they come in; pay them by check or EFT when there’s money to pay them." />
      <BillEntry onPosted={reloadAll} />
      <Card title={`To pay${open.data?.length ? `: ${open.data.length} item${open.data.length === 1 ? '' : 's'}, ${money(unpaid)}` : ''}`}>
        {open.loading && !open.data ? <Loading /> : <ToPay bills={open.data ?? []} onPaid={reloadAll} onOpen={setDetail} />}
      </Card>
      <div className="grid-2">
        <Card title="Payments made">
          {payments.data?.length ? (
            <table className="table compact">
              <thead><tr><th>Date</th><th>Paid to</th><th>How</th><th className="num">Amount</th><th /></tr></thead>
              <tbody>{payments.data.map((p) => (
                <tr key={p.id} className={p.status === 'void' ? 'void' : ''}>
                  <td className="nowrap">{date(p.pay_date)}</td>
                  <td>{p.payee_name}<div className="muted small">Bills {p.bills}</div></td>
                  <td className="small">{PAY_LABEL[p.method]}{p.reference ? ` #${p.reference}` : ''}</td>
                  <td className="num"><Money v={p.total} /></td>
                  <td>{p.status === 'posted'
                    ? <VoidButton what="payment" disabled={p.cleared} disabledReason="Cleared on a bank reconciliation"
                        onVoid={async (reason) => { await rpc('void_bill_payment', { id: p.id, reason }); toast('Payment voided; its bills are back under To pay'); refresh(); reloadAll(); }} />
                    : <Badge tone="bad">void</Badge>}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>No bill payments yet.</Empty>}
        </Card>
        <Card title="All bills & reports">
          {recent.data?.length ? (
            <table className="table compact">
              <tbody>{recent.data.slice(0, 60).map((b) => (
                <tr key={b.id} className={`clickable ${b.status === 'void' ? 'void' : ''}`} onClick={() => setDetail(b.id)}>
                  <td className="muted">#{b.bill_number}</td>
                  <td>{b.payee_name}<div className="muted small">{date(b.bill_date)} · {b.kind === 'expense_report' ? 'Expense report' : 'Bill'}{b.reference ? ` · ${b.reference}` : ''}</div></td>
                  <td className="num"><Money v={b.total} /></td>
                  <td>{b.status === 'open' ? <Badge tone="warn">to pay</Badge> : b.status === 'paid' ? <Badge tone="good">paid {date(b.paid_date)}</Badge> : <Badge tone="bad">void</Badge>}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>None yet.</Empty>}
        </Card>
      </div>
      {detail && <BillDetail id={detail} onClose={() => setDetail(null)} onChanged={reloadAll} />}
    </div>
  );
}
