import React, { useEffect, useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { date, money, num, today } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, Loading, Money, MoneyInput, PageHeader } from '../components/ui';

const LABEL: Record<string, string> = { deposit: 'Deposit', disbursement: 'Payment', opening: 'Opening balance', adjustment: 'Adjustment', reversal: 'Void / returned', gift: 'Gift', transfer: 'Transfer' };

export default function Reconcile() {
  const { toast, refresh } = useApp();
  const [stmtDate, setStmtDate] = useState<string>('');
  const ws = useRpc<any>('get_reconciliation', stmtDate ? { statement_date: stmtDate } : {});
  const hist = useRpc<any[]>('list_reconciliations');
  const [balance, setBalance] = useState('');
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    const w = ws.data;
    if (!w) return;
    if (!stmtDate) setStmtDate(w.statement_date);
    if (w.in_progress?.statement_balance != null && balance === '') setBalance(String(w.in_progress.statement_balance));
    setSel((s) => (s.size ? s : new Set(w.selected)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ws.data]);

  if (ws.loading && !ws.data) return <Loading />;
  const w = ws.data;
  if (!w) return <ErrorBox error={ws.error} />;
  const items: any[] = w.items;
  const credits = items.filter((i) => Number(i.amount) > 0);
  const debits = items.filter((i) => Number(i.amount) < 0);
  const cleared = items.filter((i) => sel.has(i.entry_id)).reduce((s, i) => s + Number(i.amount), 0);
  const begin = Number(w.beginning_balance);
  const diff = Math.round((num(balance) - (begin + cleared)) * 100) / 100;
  const toggle = (id: string) => { const s = new Set(sel); s.has(id) ? s.delete(id) : s.add(id); setSel(s); };

  const save = async (complete: boolean) => {
    setBusy(true); setErr(null);
    try {
      await rpc('save_reconciliation', { statement_date: stmtDate, statement_balance: num(balance), entry_ids: [...sel], complete });
      if (complete) {
        toast(`Reconciled to the ${date(stmtDate)} statement`);
        setSel(new Set()); setBalance(''); setStmtDate('');
        refresh(); hist.reload();
      } else toast('Saved — you can finish later');
      ws.reload();
    } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };

  const List = ({ rows, title }: { rows: any[]; title: string }) => (
    <Card title={`${title} (${rows.filter((r) => sel.has(r.entry_id)).length} of ${rows.length} cleared)`}
      actions={rows.length ? <button className="btn small" onClick={() => {
        const s = new Set(sel); const all = rows.every((r) => s.has(r.entry_id));
        rows.forEach((r) => (all ? s.delete(r.entry_id) : s.add(r.entry_id))); setSel(s);
      }}>Toggle all</button> : null}>
      {rows.length ? (
        <table className="table compact">
          <tbody>{rows.map((r) => (
            <tr key={r.entry_id} className={`clickable ${sel.has(r.entry_id) ? 'selected' : ''}`} onClick={() => toggle(r.entry_id)}>
              <td><input type="checkbox" checked={sel.has(r.entry_id)} onChange={() => toggle(r.entry_id)} onClick={(e) => e.stopPropagation()} /></td>
              <td className="nowrap">{date(r.entry_date)}</td>
              <td><span className="muted small">{LABEL[r.source_type] ?? r.source_type}</span><div>{r.label}</div></td>
              <td className="num"><Money v={Math.abs(r.amount)} /></td>
            </tr>
          ))}</tbody>
        </table>
      ) : <Empty>None.</Empty>}
    </Card>
  );

  return (
    <div>
      <PageHeader title="Bank reconciliation" subtitle="Tick each deposit and payment that appears on the bank statement. When the difference is $0.00, the books agree with the bank." />
      <Card className="recon-head">
        <div className="form-grid">
          <Field label="Statement ending date"><input type="date" value={stmtDate} max={today()} onChange={(e) => setStmtDate(e.target.value)} /></Field>
          <Field label="Statement ending balance"><MoneyInput value={balance} onChange={setBalance} autoFocus /></Field>
        </div>
        <div className="recon-math">
          <div><span>Beginning balance{w.last_completed ? ` (${date(w.last_completed.statement_date)})` : ''}</span><Money v={begin} accounting /></div>
          <div><span>+ Cleared deposits</span><Money v={credits.filter((r) => sel.has(r.entry_id)).reduce((s, r) => s + Number(r.amount), 0)} /></div>
          <div><span>− Cleared payments</span><Money v={Math.abs(debits.filter((r) => sel.has(r.entry_id)).reduce((s, r) => s + Number(r.amount), 0))} /></div>
          <div><span>= Cleared balance</span><Money v={begin + cleared} accounting /></div>
          <div><span>Statement balance</span><Money v={num(balance)} accounting /></div>
          <div className={`diff ${diff === 0 && balance !== '' ? 'ok' : 'off'}`}><span>Difference</span><Money v={diff} accounting /></div>
        </div>
        <div className="muted small">Books show {money(w.book_balance)} in the bank as of {date(w.statement_date)}. Items dated after the statement date are not listed.</div>
        <ErrorBox error={err} />
        <div className="form-actions">
          <button className="btn primary" disabled={busy || diff !== 0 || balance === ''} onClick={() => save(true)}>Finish reconciliation</button>
          <button className="btn" disabled={busy || balance === ''} onClick={() => save(false)}>Save for later</button>
          {w.in_progress && <button className="btn" onClick={async () => { await rpc('discard_reconciliation'); setSel(new Set()); setBalance(''); ws.reload(); }}>Discard</button>}
        </div>
      </Card>
      <div className="grid-2">
        <List rows={credits} title="Deposits & credits" />
        <List rows={debits} title="Payments & charges" />
      </div>
      <Card title="Completed reconciliations" actions={hist.data?.length ? (
        <button className="btn small" onClick={async () => {
          if (!confirm('Reopen the most recent reconciliation so you can correct it?')) return;
          try { await rpc('reopen_last_reconciliation'); toast('Reopened'); hist.reload(); setSel(new Set()); setBalance(''); setStmtDate(''); ws.reload(); } catch (e: any) { toast(e.message, 'error'); }
        }}>Reopen last</button>) : null}>
        {hist.data?.length ? (
          <table className="table compact">
            <thead><tr><th>Statement date</th><th className="num">Beginning</th><th className="num">Ending</th><th>Items</th><th>Completed</th></tr></thead>
            <tbody>{hist.data.map((r) => (
              <tr key={r.id}><td>{date(r.statement_date)}</td><td className="num"><Money v={r.beginning_balance} /></td><td className="num"><Money v={r.statement_balance} /></td>
                <td>{r.item_count}</td><td className="small muted">{new Date(r.completed_at).toLocaleString()} · {r.completed_by} <Badge tone="good">✓</Badge></td></tr>
            ))}</tbody>
          </table>
        ) : <Empty>No reconciliations yet. Your first one starts from a $0.00 beginning balance and includes the opening balance entry.</Empty>}
      </Card>
    </div>
  );
}
