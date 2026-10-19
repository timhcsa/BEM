import React, { useEffect, useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { METHODS, date, money, today } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, Loading, Modal, Money, PageHeader, VoidButton } from '../components/ui';

function DepositDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { data: d, reload } = useRpc<any>('get_deposit', { id });
  const { toast, refresh } = useApp();
  if (!d) return null;
  return (
    <Modal title={<>Deposit #{d.deposit_number} {d.status === 'void' && <Badge tone="bad">VOID</Badge>} {d.cleared && <Badge tone="good">cleared</Badge>}</>}
      onClose={onClose} size="lg"
      footer={<>
        <button className="btn" onClick={() => window.print()}>Print</button>
        {d.status === 'posted' && (
          <VoidButton what="deposit" disabled={d.cleared} disabledReason="Already reconciled with a bank statement"
            onVoid={async (reason) => { await rpc('void_deposit', { id, reason }); toast('Deposit voided; its gifts are undeposited again'); refresh(); reload(); onChanged(); }} />
        )}
        <button className="btn" onClick={onClose}>Close</button>
      </>}>
      <div className="print-area">
        <dl className="dl">
          <dt>Date</dt><dd>{date(d.deposit_date)}</dd>
          <dt>Total</dt><dd><Money v={d.total} /></dd>
          {d.memo && <><dt>Memo</dt><dd>{d.memo}</dd></>}
          {d.status === 'void' && <><dt>Voided</dt><dd>{d.void_reason}</dd></>}
        </dl>
        <h3 className="section-label">Gifts in this deposit</h3>
        <table className="table compact">
          <thead><tr><th>#</th><th>Date</th><th>Donor</th><th>Received as</th><th className="num">Amount</th></tr></thead>
          <tbody>{d.gifts.map((g: any) => (
            <tr key={g.id} className={g.status === 'void' ? 'void' : ''}><td>{g.gift_number}</td><td>{date(g.gift_date)}</td><td>{g.donor_name}</td>
              <td>{METHODS[g.method]} {g.reference}</td><td className="num"><Money v={g.total_amount} /></td></tr>
          ))}</tbody>
        </table>
        <h3 className="section-label">By fund</h3>
        <table className="table compact">
          <tbody>{d.by_fund.map((f: any) => <tr key={f.fund_name}><td>{f.fund_name}</td><td className="num"><Money v={f.amount} /></td></tr>)}</tbody>
        </table>
      </div>
    </Modal>
  );
}

export default function Deposits() {
  const { toast, refresh } = useApp();
  const und = useRpc<any[]>('list_undeposited_gifts');
  const hist = useRpc<any[]>('list_deposits', { limit: 100 });
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [depDate, setDepDate] = useState(today());
  const [memo, setMemo] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<string | null>(null);

  const gifts = und.data ?? [];
  useEffect(() => { setSel(new Set(gifts.map((g) => g.id))); }, [und.data]);
  const selected = gifts.filter((g) => sel.has(g.id));
  const total = selected.reduce((s, g) => s + Number(g.total_amount), 0);
  const byMethod = selected.reduce((m: Record<string, number>, g) => { m[g.method] = (m[g.method] ?? 0) + Number(g.total_amount); return m; }, {});
  const toggle = (id: string) => { const s = new Set(sel); s.has(id) ? s.delete(id) : s.add(id); setSel(s); };

  const post = async () => {
    setBusy(true); setErr(null);
    try {
      const d = await rpc('post_deposit', { deposit_date: depDate, memo, gift_ids: selected.map((g) => g.id) });
      toast(`Deposit #${d.deposit_number} recorded — ${money(d.total)}`);
      setMemo(''); und.reload(); hist.reload(); refresh();
    } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };

  return (
    <div>
      <PageHeader title="Deposits" subtitle="Group the gifts you take to the bank (or that arrive in one online payout) so the ledger matches the bank statement line for line." />
      <Card title="Gifts waiting to be deposited">
        {und.loading && !und.data ? <Loading /> : gifts.length ? (
          <>
            <table className="table">
              <thead><tr>
                <th><input type="checkbox" aria-label="Select all" checked={sel.size === gifts.length} onChange={(e) => setSel(e.target.checked ? new Set(gifts.map((g) => g.id)) : new Set())} /></th>
                <th>#</th><th>Date</th><th>Donor</th><th>Designation</th><th>Received as</th><th className="num">Amount</th></tr></thead>
              <tbody>
                {gifts.map((g) => (
                  <tr key={g.id} className="clickable" onClick={() => toggle(g.id)}>
                    <td><input type="checkbox" checked={sel.has(g.id)} onChange={() => toggle(g.id)} onClick={(e) => e.stopPropagation()} /></td>
                    <td className="muted">{g.gift_number}</td><td>{date(g.gift_date)}</td><td>{g.donor_name}</td>
                    <td className="small">{g.funds}</td><td className="small">{METHODS[g.method]} {g.reference}</td>
                    <td className="num"><Money v={g.total_amount} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="deposit-bar">
              <div>
                <div className="big-total"><Money v={total} /></div>
                <div className="muted small">{selected.length} gift{selected.length === 1 ? '' : 's'} · {Object.entries(byMethod).map(([k, v]) => `${METHODS[k]} ${money(v)}`).join(' · ')}</div>
              </div>
              <Field label="Deposit date (as on the bank statement)"><input type="date" value={depDate} onChange={(e) => setDepDate(e.target.value)} /></Field>
              <Field label="Memo (optional)"><input value={memo} onChange={(e) => setMemo(e.target.value)} placeholder="e.g. Zeffy payout" /></Field>
              <button className="btn primary" disabled={busy || !selected.length} onClick={post}>Record deposit</button>
            </div>
            <ErrorBox error={err} />
          </>
        ) : <Empty>Nothing waiting. Every gift has been deposited.</Empty>}
      </Card>

      <Card title="Deposit history">
        {hist.data?.length ? (
          <table className="table">
            <thead><tr><th>#</th><th>Date</th><th>Gifts</th><th>Memo</th><th className="num">Amount</th><th>Bank</th></tr></thead>
            <tbody>
              {hist.data.map((d) => (
                <tr key={d.id} className={`clickable ${d.status === 'void' ? 'void' : ''}`} onClick={() => setOpen(d.id)}>
                  <td className="muted">{d.deposit_number}</td><td>{date(d.deposit_date)}</td><td>{d.gift_count}</td><td>{d.memo}</td>
                  <td className="num"><Money v={d.total} /></td>
                  <td>{d.status === 'void' ? <Badge tone="bad">void</Badge> : d.cleared ? <Badge tone="good">cleared</Badge> : <Badge>uncleared</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        ) : <Empty>No deposits yet.</Empty>}
      </Card>
      {open && <DepositDetail id={open} onClose={() => setOpen(null)} onChanged={() => { und.reload(); hist.reload(); }} />}
    </div>
  );
}
