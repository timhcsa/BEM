import React, { useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { date, money, num, today } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, FundSelect, Modal, Money, MoneyInput, PageHeader, VoidButton } from '../components/ui';

function TransferForm({ onPosted }: { onPosted: () => void }) {
  const { lookups, toast, refresh } = useApp();
  const funds = lookups?.funds ?? [];
  const [t, setT] = useState({ transfer_date: today(), from_fund_id: '', to_fund_id: '', amount: '', reason: '' });
  const [err, setErr] = useState<string | null>(null);
  const [over, setOver] = useState<string | null>(null);
  const from = funds.find((f) => f.id === t.from_fund_id);
  const post = async (allow = false) => {
    setErr(null);
    try {
      await rpc('post_transfer', { ...t, amount: num(t.amount), allow_overdraft: allow });
      toast('Transfer recorded'); setT({ ...t, amount: '', reason: '' }); setOver(null); refresh(); onPosted();
    } catch (e: any) { e.message.startsWith('OVERDRAFT') ? setOver(e.message.replace('OVERDRAFT: ', '')) : setErr(e.message); }
  };
  return (
    <Card title="Transfer between funds">
      <p className="muted small">Moves money from one fund to another without touching the bank (for example, a board-approved grant from the General Fund to a missionary). Administrative fees are handled automatically — don't enter them here.</p>
      <div className="form-grid">
        <Field label="Date"><input type="date" value={t.transfer_date} onChange={(e) => setT({ ...t, transfer_date: e.target.value })} /></Field>
        <Field label="From fund" hint={from ? `Balance ${money(from.balance)}` : undefined}><FundSelect funds={funds} value={t.from_fund_id} onChange={(v) => setT({ ...t, from_fund_id: v })} /></Field>
        <Field label="To fund"><FundSelect funds={funds} value={t.to_fund_id} onChange={(v) => setT({ ...t, to_fund_id: v })} /></Field>
        <Field label="Amount"><MoneyInput value={t.amount} onChange={(v) => setT({ ...t, amount: v })} /></Field>
        <Field label="Reason (shows on fund statements)" wide><input value={t.reason} onChange={(e) => setT({ ...t, reason: e.target.value })} placeholder="e.g. Board-approved help with medical bills, minutes 9/14" /></Field>
      </div>
      <ErrorBox error={err} />
      <div className="form-actions"><button className="btn primary" onClick={() => post(false)}>Record transfer</button></div>
      {over && (
        <Modal title="This would overdraw a fund" size="sm" onClose={() => setOver(null)}
          footer={<><button className="btn" onClick={() => setOver(null)}>Go back</button><button className="btn danger" onClick={() => post(true)}>Record anyway</button></>}>
          <p><strong>{over}</strong></p>
        </Modal>
      )}
    </Card>
  );
}

type JLine = { key: number; account_id: string; fund_id: string; debit: string; credit: string; memo: string };
let k = 1;
const jl = (): JLine => ({ key: k++, account_id: '', fund_id: '', debit: '', credit: '', memo: '' });

function JournalForm({ onPosted }: { onPosted: () => void }) {
  const { lookups, toast, refresh } = useApp();
  const [entryDate, setEntryDate] = useState(today());
  const [memo, setMemo] = useState('');
  const [lines, setLines] = useState<JLine[]>([jl(), jl()]);
  const [err, setErr] = useState<string | null>(null);
  const accounts = (lookups?.accounts ?? []).filter((a) => a.active);
  const dr = lines.reduce((s, l) => s + num(l.debit), 0);
  const cr = lines.reduce((s, l) => s + num(l.credit), 0);
  const upd = (key: number, p: Partial<JLine>) => setLines(lines.map((l) => (l.key === key ? { ...l, ...p } : l)));
  return (
    <Card title="General journal entry">
      <p className="muted small">For corrections and items that aren't gifts or payments: bank interest, a bank error, reclassifying an expense between funds. Each fund's debits must equal its credits.</p>
      <div className="form-grid">
        <Field label="Date"><input type="date" value={entryDate} onChange={(e) => setEntryDate(e.target.value)} /></Field>
        <Field label="Description" wide><input value={memo} onChange={(e) => setMemo(e.target.value)} placeholder="e.g. September interest" /></Field>
      </div>
      <table className="table lines">
        <thead><tr><th>Account</th><th>Fund</th><th className="num">Debit</th><th className="num">Credit</th><th>Note</th><th /></tr></thead>
        <tbody>{lines.map((l) => (
          <tr key={l.key}>
            <td><select value={l.account_id} onChange={(e) => upd(l.key, { account_id: e.target.value })}>
              <option value="">Choose…</option>{accounts.map((a) => <option key={a.id} value={a.id}>{a.code} · {a.name}</option>)}</select></td>
            <td><FundSelect funds={lookups?.funds ?? []} value={l.fund_id} onChange={(v) => upd(l.key, { fund_id: v })} /></td>
            <td style={{ width: 130 }}><MoneyInput value={l.debit} onChange={(v) => upd(l.key, { debit: v, credit: v ? '' : l.credit })} placeholder="" /></td>
            <td style={{ width: 130 }}><MoneyInput value={l.credit} onChange={(v) => upd(l.key, { credit: v, debit: v ? '' : l.debit })} placeholder="" /></td>
            <td><input value={l.memo} onChange={(e) => upd(l.key, { memo: e.target.value })} /></td>
            <td>{lines.length > 2 && <button className="icon-btn" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>×</button>}</td>
          </tr>
        ))}</tbody>
        <tfoot><tr>
          <td colSpan={2}><button className="btn small" onClick={() => setLines([...lines, jl()])}>+ Line</button></td>
          <td className="num total-cell">{money(dr)}</td><td className="num total-cell">{money(cr)}</td>
          <td colSpan={2}>{Math.abs(dr - cr) > 0.001 ? <Badge tone="bad">Out of balance by {money(Math.abs(dr - cr))}</Badge> : dr > 0 ? <Badge tone="good">Balanced</Badge> : null}</td>
        </tr></tfoot>
      </table>
      <ErrorBox error={err} />
      <div className="form-actions">
        <button className="btn primary" disabled={dr === 0 || Math.abs(dr - cr) > 0.001} onClick={async () => {
          setErr(null);
          try {
            await rpc('post_journal_entry', { entry_date: entryDate, memo, lines: lines.filter((l) => l.account_id || l.fund_id || num(l.debit) || num(l.credit))
              .map((l) => ({ account_id: l.account_id, fund_id: l.fund_id, debit: num(l.debit), credit: num(l.credit), memo: l.memo })) });
            toast('Journal entry posted'); setMemo(''); setLines([jl(), jl()]); refresh(); onPosted();
          } catch (e: any) { setErr(e.message); }
        }}>Post entry</button>
      </div>
    </Card>
  );
}

export default function Adjustments() {
  const { toast, refresh } = useApp();
  const transfers = useRpc<any[]>('list_transfers');
  const ledger = useRpc<any>('report_general_ledger', { from: '2000-01-01', to: '2999-12-31' });
  const entries = Object.values(((ledger.data?.rows ?? []) as any[])
    .filter((r) => r.source_type === 'adjustment' || r.source_type === 'opening')
    .reduce((m: Record<string, any>, r) => { (m[r.entry_id] ??= { ...r, lines: [] }).lines.push(r); return m; }, {})).reverse();
  return (
    <div>
      <PageHeader title="Transfers & adjustments" subtitle="Interfund transfers and general journal entries." />
      <div className="grid-2">
        <TransferForm onPosted={transfers.reload} />
        <Card title="Recent transfers">
          {transfers.data?.length ? (
            <table className="table compact">
              <tbody>{transfers.data.slice(0, 30).map((t) => (
                <tr key={t.id} className={t.status === 'void' ? 'void' : ''}>
                  <td className="nowrap">{date(t.transfer_date)}</td>
                  <td>{t.from_name} → {t.to_name}<div className="muted small">{t.reason}</div></td>
                  <td className="num"><Money v={t.amount} /></td>
                  <td>{t.status === 'posted' ? <VoidButton what="transfer" onVoid={async (reason) => { await rpc('void_transfer', { id: t.id, reason }); toast('Transfer voided'); refresh(); transfers.reload(); }} /> : <Badge tone="bad">void</Badge>}</td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>No transfers yet.</Empty>}
        </Card>
      </div>
      <JournalForm onPosted={ledger.reload} />
      <Card title="Journal entries">
        {entries.length ? (
          <table className="table compact">
            <thead><tr><th>#</th><th>Date</th><th>Description</th><th>Lines</th><th /></tr></thead>
            <tbody>{entries.map((e: any) => (
              <tr key={e.entry_id}>
                <td className="muted">{e.entry_number}</td><td className="nowrap">{date(e.entry_date)}</td><td>{e.label}</td>
                <td className="small">{e.lines.map((l: any, i: number) => <div key={i}>{l.account_code} {l.fund_name}: {Number(l.debit) ? `Dr ${money(l.debit)}` : `Cr ${money(l.credit)}`}</div>)}</td>
                <td><VoidButton what="entry" onVoid={async (reason) => { await rpc('void_journal_entry', { id: e.entry_id, reason }); toast('Entry reversed'); refresh(); ledger.reload(); }} /></td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>No journal entries yet.</Empty>}
      </Card>
    </div>
  );
}
