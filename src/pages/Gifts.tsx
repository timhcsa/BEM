import React, { useEffect, useMemo, useRef, useState } from 'react';
import { rpc } from '../lib/api';
import { go, routeQuery, useApp, useRpc } from '../lib/store';
import { METHODS, date, download, money, num, periods, toCsv, today, type Period } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, FundSelect, Loading, Modal, Money, MoneyInput, PageHeader, PeriodPicker, VoidButton } from '../components/ui';
import { DonorPicker, type Donor } from '../components/donors';

type Line = { key: number; fund_id: string; amount: string; fee_exempt: boolean; memo: string; fee?: any };
let lineKey = 1;
const newLine = (fund_id = ''): Line => ({ key: lineKey++, fund_id, amount: '', fee_exempt: false, memo: '' });

export function GiftEntry({ onPosted, prefill }: { onPosted?: (g: any) => void; prefill?: any }) {
  const { lookups, toast, refresh } = useApp();
  const funds = lookups?.funds ?? [];
  const [donor, setDonor] = useState<Donor | null>(prefill?.donor ?? null);
  const [anonymous, setAnonymous] = useState(false);
  const [giftDate, setGiftDate] = useState<string>(prefill?.gift_date ?? sessionStorage.getItem('bem.giftDate') ?? today());
  const [method, setMethod] = useState<string>(prefill?.method ?? sessionStorage.getItem('bem.method') ?? 'check');
  const [reference, setReference] = useState(prefill?.reference ?? '');
  const [memo, setMemo] = useState(prefill?.memo ?? '');
  const [lines, setLines] = useState<Line[]>(
    prefill?.lines?.map((l: any) => ({ ...newLine(l.fund_id), amount: String(l.amount), fee_exempt: l.fee_exempt, memo: l.memo ?? '' })) ?? [newLine()]);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [batch, setBatch] = useState<any[]>([]);
  const firstAmount = useRef<HTMLInputElement>(null);

  const total = lines.reduce((s, l) => s + num(l.amount), 0);

  // Fee preview for missionary lines
  const previewKey = lines.map((l) => `${l.fund_id}:${l.amount}:${l.fee_exempt}`).join('|') + giftDate;
  useEffect(() => {
    let live = true;
    Promise.all(lines.map((l) => (l.fund_id && num(l.amount) > 0 && !l.fee_exempt
      ? rpc('preview_admin_fee', { fund_id: l.fund_id, amount: num(l.amount), gift_date: giftDate }) : Promise.resolve(null))))
      .then((fees) => { if (live) setLines((ls) => ls.map((l, i) => ({ ...l, fee: fees[i] }))); })
      .catch(() => {});
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewKey]);

  const update = (key: number, patch: Partial<Line>) => setLines((ls) => ls.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const save = async () => {
    setErr(null);
    if (!donor && !anonymous) { setErr('Choose a donor (or tick “Anonymous / loose cash”).'); return; }
    const filled = lines.filter((l) => l.fund_id || num(l.amount));
    if (!filled.length) { setErr('Enter a fund and an amount.'); return; }
    if (filled.some((l) => !l.fund_id)) { setErr('Choose a fund for every amount.'); return; }
    if (filled.some((l) => num(l.amount) <= 0)) { setErr('Every designation needs an amount above $0.00.'); return; }
    setBusy(true);
    try {
      const g = await rpc('post_gift', {
        donor_id: anonymous ? null : donor!.id, gift_date: giftDate, method, reference, memo,
        lines: filled.map((l) => ({ fund_id: l.fund_id, amount: num(l.amount), fee_exempt: l.fee_exempt, memo: l.memo })),
      });
      sessionStorage.setItem('bem.giftDate', giftDate);
      sessionStorage.setItem('bem.method', method);
      toast(`Gift #${g.gift_number} saved — ${money(g.total_amount)} from ${g.donor?.display_name ?? 'anonymous'}`);
      setBatch((b) => [g, ...b]);
      setDonor(null); setAnonymous(false); setReference(''); setMemo(''); setLines([newLine()]);
      refresh();
      onPosted?.(g);
    } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };

  const batchTotal = batch.reduce((s, g) => s + Number(g.total_amount), 0);

  return (
    <div className="gift-entry">
      <Card title="Enter a gift">
        <div className="form-grid">
          <Field label="Donor" wide>
            {anonymous
              ? <div className="donor-chosen"><strong>Anonymous / loose cash</strong><button className="btn small" onClick={() => setAnonymous(false)}>Change</button></div>
              : <DonorPicker value={donor} onChange={(d) => { setDonor(d); if (d) setTimeout(() => firstAmount.current?.focus(), 0); }} autoFocus />}
            {!donor && !anonymous && <button type="button" className="linklike small" onClick={() => setAnonymous(true)}>Anonymous / loose cash</button>}
          </Field>
          <Field label="Date received"><input type="date" value={giftDate} onChange={(e) => setGiftDate(e.target.value)} /></Field>
          <Field label="Received as">
            <select value={method} onChange={(e) => setMethod(e.target.value)}>
              {Object.entries(METHODS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </Field>
          <Field label={method === 'check' ? 'Check number' : 'Reference / transaction #'}><input value={reference} onChange={(e) => setReference(e.target.value)} /></Field>
          <Field label="Note (optional)"><input value={memo} onChange={(e) => setMemo(e.target.value)} placeholder="e.g. in memory of…" /></Field>
        </div>

        <h3 className="section-label">Designation</h3>
        <table className="table lines">
          <thead><tr><th>Fund</th><th className="num">Amount</th><th>Admin fee</th><th>Line note</th><th /></tr></thead>
          <tbody>
            {lines.map((l, i) => {
              const f = funds.find((x) => x.id === l.fund_id);
              return (
                <tr key={l.key}>
                  <td style={{ minWidth: 220 }}><FundSelect funds={funds} value={l.fund_id} onChange={(id) => update(l.key, { fund_id: id })} /></td>
                  <td style={{ width: 150 }}><MoneyInput inputRef={i === 0 ? firstAmount : undefined} value={l.amount} onChange={(v) => update(l.key, { amount: v })} /></td>
                  <td className="small">
                    {f?.admin_fee_applies ? (
                      <>
                        <label className="check inline"><input type="checkbox" checked={l.fee_exempt} onChange={(e) => update(l.key, { fee_exempt: e.target.checked })} /> exempt</label>
                        {!l.fee_exempt && l.fee?.applies && (
                          <div className="muted">{money(l.fee.fee)} to General{Number(l.fee.charged_this_month) >= Number(l.fee.cap) ? ' (monthly cap reached)' : ''}</div>
                        )}
                      </>
                    ) : <span className="muted">—</span>}
                  </td>
                  <td><input value={l.memo} onChange={(e) => update(l.key, { memo: e.target.value })} /></td>
                  <td>{lines.length > 1 && <button className="icon-btn" aria-label="Remove line" onClick={() => setLines(lines.filter((x) => x.key !== l.key))}>×</button>}</td>
                </tr>
              );
            })}
          </tbody>
          <tfoot>
            <tr>
              <td><button className="btn small" onClick={() => setLines([...lines, newLine()])}>+ Split to another fund</button></td>
              <td className="num total-cell"><Money v={total} /></td>
              <td colSpan={3} />
            </tr>
          </tfoot>
        </table>
        <ErrorBox error={err} />
        <div className="form-actions">
          <button className="btn primary" disabled={busy} onClick={save}>{busy ? 'Saving…' : 'Save gift'}</button>
          <span className="muted small">Gifts go to <em>Undeposited Gifts</em> until you record the bank deposit.</span>
        </div>
      </Card>
      {batch.length > 0 && (
        <Card title={`Entered this session: ${batch.length} gift${batch.length === 1 ? '' : 's'}, ${money(batchTotal)}`}
          actions={<a className="btn small" href="#/deposits">Deposit these →</a>}>
          <table className="table compact">
            <tbody>
              {batch.map((g) => (
                <tr key={g.id}><td>#{g.gift_number}</td><td>{g.donor?.display_name ?? 'Anonymous'}</td><td className="muted">{METHODS[g.method]} {g.reference}</td>
                  <td className="muted small">{g.lines.map((l: any) => l.fund_name).join(', ')}</td><td className="num"><Money v={g.total_amount} /></td></tr>
              ))}
            </tbody>
          </table>
        </Card>
      )}
    </div>
  );
}

export function GiftDetail({ id, onClose, onChanged }: { id: string; onClose: () => void; onChanged: () => void }) {
  const { data: g, error, reload } = useRpc<any>('get_gift', { id });
  const { toast, refresh } = useApp();
  const [reference, setReference] = useState<string | null>(null);
  const [memo, setMemo] = useState<string | null>(null);
  if (error) return <Modal title="Gift" onClose={onClose}><ErrorBox error={error} /></Modal>;
  if (!g) return null;
  const reenter = () => {
    sessionStorage.setItem('bem.prefill', JSON.stringify({ donor: g.donor, gift_date: g.gift_date, method: g.method, reference: g.reference, memo: g.memo, lines: g.lines }));
    go('gifts/new?prefill=1');
  };
  return (
    <Modal title={<>Gift #{g.gift_number} {g.status === 'void' && <Badge tone="bad">VOID</Badge>}</>} onClose={onClose} size="lg"
      footer={<>
        {g.status === 'posted' && (
          <VoidButton what="gift" onVoid={async (reason) => {
            await rpc('void_gift', { id, reason }); toast(`Gift #${g.gift_number} voided`); refresh(); reload(); onChanged();
          }} />
        )}
        {g.status === 'void' && <button className="btn" onClick={reenter}>Re-enter corrected gift</button>}
        <button className="btn" onClick={onClose}>Close</button>
      </>}>
      <dl className="dl">
        <dt>Donor</dt><dd>{g.donor ? <a href={`#/donors/${g.donor.id}`}>{g.donor.display_name}</a> : 'Anonymous'}</dd>
        <dt>Date received</dt><dd>{date(g.gift_date)}</dd>
        <dt>Received as</dt><dd>{METHODS[g.method]}</dd>
        <dt>Total</dt><dd><Money v={g.total_amount} /></dd>
        <dt>Deposit</dt><dd>{g.deposit_number ? `Deposit #${g.deposit_number}` : <Badge tone="warn">Not yet deposited</Badge>}</dd>
        <dt>Entered</dt><dd className="muted">{new Date(g.created_at).toLocaleString()} by {g.created_by}</dd>
        {g.status === 'void' && <><dt>Voided</dt><dd>{new Date(g.voided_at).toLocaleString()} — {g.void_reason}</dd></>}
      </dl>
      <table className="table">
        <thead><tr><th>Fund</th><th className="num">Amount</th><th className="num">Admin fee</th><th>Note</th></tr></thead>
        <tbody>
          {g.lines.map((l: any) => (
            <tr key={l.id}><td>{l.fund_name}</td><td className="num"><Money v={l.amount} /></td>
              <td className="num">{l.fee_exempt ? <span className="muted">exempt</span> : <Money v={l.admin_fee} />}</td><td>{l.memo}</td></tr>
          ))}
        </tbody>
      </table>
      {g.status === 'posted' && (
        <div className="form-grid">
          <Field label="Check / reference #"><input value={reference ?? g.reference ?? ''} onChange={(e) => setReference(e.target.value)} /></Field>
          <Field label="Note"><input value={memo ?? g.memo ?? ''} onChange={(e) => setMemo(e.target.value)} /></Field>
          <div className="field"><span className="label">&nbsp;</span>
            <button className="btn" disabled={reference === null && memo === null} onClick={async () => {
              await rpc('update_gift_details', { id, reference: reference ?? g.reference, memo: memo ?? g.memo });
              toast('Saved'); setReference(null); setMemo(null); reload(); onChanged();
            }}>Save note / reference</button>
          </div>
        </div>
      )}
      <p className="muted small">To change the donor, date, amount or fund: void this gift and re-enter it. The ledger keeps both records for the audit trail.</p>
    </Modal>
  );
}

export default function Gifts({ sub }: { sub?: string }) {
  const { lookups } = useApp();
  const [period, setPeriod] = useState<Period>(periods().this_month);
  const [fundId, setFundId] = useState('');
  const [q, setQ] = useState('');
  const [status, setStatus] = useState('');
  const params = useMemo(() => ({ from: period.from, to: period.to, fund_id: fundId, q, status }), [period, fundId, q, status]);
  const { data, loading, error, reload } = useRpc<any[]>('list_gifts', params);
  const qs = routeQuery();
  const openId = qs.get('open');
  const prefill = useMemo(() => {
    if (qs.get('prefill')) { const p = sessionStorage.getItem('bem.prefill'); sessionStorage.removeItem('bem.prefill'); return p ? JSON.parse(p) : null; }
    return null;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [window.location.hash]);

  if (sub === 'new') {
    return (
      <div>
        <PageHeader title="Enter gifts" subtitle="Find the donor, choose where the gift goes, save. Repeat for each check in the batch."
          actions={<a className="btn" href="#/gifts">Gift register</a>} />
        <GiftEntry prefill={prefill} />
      </div>
    );
  }

  const rows = data ?? [];
  const total = rows.filter((g) => g.status === 'posted').reduce((s, g) => s + Number(g.total_amount), 0);
  return (
    <div>
      <PageHeader title="Gifts" subtitle="Every contribution received, with its designation."
        actions={<>
          <button className="btn" onClick={() => download(`gifts-${period.from}-to-${period.to}.csv`, toCsv(rows, [
            ['gift_number', 'Gift #'], ['gift_date', 'Date'], ['donor_name', 'Donor'], ['funds', 'Funds'], ['method', 'Method'],
            ['reference', 'Reference'], ['total_amount', 'Amount'], ['admin_fee', 'Admin fee'], ['deposit_number', 'Deposit #'], ['status', 'Status']]), 'text/csv')}>Export CSV</button>
          <a className="btn primary" href="#/gifts/new">+ Enter gifts</a>
        </>} />
      <div className="filters no-print">
        <PeriodPicker value={period} onChange={setPeriod} />
        <FundSelect funds={lookups?.funds ?? []} value={fundId} onChange={setFundId} includeInactive placeholder="All funds" />
        <select value={status} onChange={(e) => setStatus(e.target.value)}>
          <option value="">Posted & void</option><option value="posted">Posted only</option><option value="void">Void only</option>
        </select>
        <input type="search" placeholder="Donor, check # or gift #" value={q} onChange={(e) => setQ(e.target.value)} />
      </div>
      <ErrorBox error={error} />
      <Card>
        {loading && !data ? <Loading /> : rows.length ? (
          <table className="table">
            <thead><tr><th>#</th><th>Date</th><th>Donor</th><th>Designation</th><th>Received as</th><th className="num">Amount</th><th className="num">Admin fee</th><th>Deposit</th></tr></thead>
            <tbody>
              {rows.map((g) => (
                <tr key={g.id} className={`clickable ${g.status === 'void' ? 'void' : ''}`} onClick={() => go(`gifts?open=${g.id}`)}>
                  <td className="muted">{g.gift_number}</td>
                  <td className="nowrap">{date(g.gift_date)}</td>
                  <td>{g.donor_name}</td>
                  <td className="small">{g.funds}</td>
                  <td className="small">{METHODS[g.method]}{g.reference ? ` #${g.reference}` : ''}</td>
                  <td className="num"><Money v={g.total_amount} /></td>
                  <td className="num muted"><Money v={g.admin_fee} /></td>
                  <td>{g.status === 'void' ? <Badge tone="bad">void</Badge> : g.deposit_number ? <span className="muted small">#{g.deposit_number}</span> : <Badge tone="warn">undeposited</Badge>}</td>
                </tr>
              ))}
            </tbody>
            <tfoot><tr className="total"><td colSpan={5}>{rows.filter((g) => g.status === 'posted').length} posted gifts</td><td className="num"><Money v={total} /></td><td colSpan={2} /></tr></tfoot>
          </table>
        ) : <Empty>No gifts in this period.</Empty>}
      </Card>
      {openId && <GiftDetail id={openId} onClose={() => go('gifts')} onChanged={reload} />}
    </div>
  );
}
