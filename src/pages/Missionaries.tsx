import React, { useMemo, useRef, useState } from 'react';
import { rpc } from '../lib/api';
import { go, useApp, useRpc } from '../lib/store';
import { date, money, monthLabel, periods, resizeImage, type Period } from '../lib/format';
import { PayeeForm } from './Payees';
import { Avatar, Badge, Bars, Card, Empty, ErrorBox, Field, Loading, Modal, Money, PageHeader, PeriodPicker } from '../components/ui';

export function MissionaryForm({ initial, onClose, onSaved }: { initial?: any; onClose: () => void; onSaved: (m: any) => void }) {
  const { settings } = useApp().lookups ?? ({} as any);
  const [m, setM] = useState<any>(initial ?? { active: true, admin_fee_applies: true, restriction: 'with' });
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const set = (k: string) => (e: any) => setM({ ...m, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  const save = async () => {
    setBusy(true); setErr(null);
    try { onSaved(await rpc('save_missionary', m)); } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };
  return (
    <Modal title={m.id ? `Edit ${m.display_name}` : 'Add a missionary'} onClose={onClose} size="lg"
      footer={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy} onClick={save}>Save</button></>}>
      <div className="photo-edit">
        <Avatar name={m.display_name || '?'} url={m.photo_url} size={96} />
        <div>
          <button className="btn small" onClick={() => file.current?.click()}>Upload photo</button>
          {m.photo_url && <button className="btn small" onClick={() => setM({ ...m, photo_url: '' })}>Remove</button>}
          <input ref={file} type="file" accept="image/*" hidden onChange={async (e) => {
            const f = e.target.files?.[0]; if (!f) return;
            try { setM({ ...m, photo_url: await resizeImage(f) }); } catch (x: any) { setErr(x.message); }
          }} />
          <Field label="…or photo web address"><input value={m.photo_url?.startsWith('data:') ? '(uploaded photo)' : m.photo_url ?? ''} onChange={set('photo_url')} /></Field>
        </div>
      </div>
      <div className="form-grid">
        <Field label="Name as shown" wide hint="e.g. “Ted & Marlene Sutherland”. This is also the fund name."><input autoFocus value={m.display_name ?? ''} onChange={set('display_name')} /></Field>
        <Field label="Role / title"><input value={m.role_title ?? ''} onChange={set('role_title')} /></Field>
        <Field label="Email"><input value={m.email ?? ''} onChange={set('email')} /></Field>
        <Field label="Phone"><input value={m.phone ?? ''} onChange={set('phone')} /></Field>
        <Field label="Start date"><input type="date" value={m.start_date ?? ''} onChange={set('start_date')} /></Field>
        <Field label="Mailing address" wide><input value={m.address ?? ''} onChange={set('address')} /></Field>
        <Field label="Notes" wide><textarea rows={2} value={m.bio ?? ''} onChange={set('bio')} /></Field>
        <Field label="Display order"><input type="number" value={m.sort ?? 50} onChange={set('sort')} /></Field>
      </div>
      <h3 className="section-label">Administrative fee</h3>
      <div className="form-grid">
        <label className="check"><input type="checkbox" checked={m.admin_fee_applies !== false} onChange={set('admin_fee_applies')} /> Charge the administrative fee on gifts to this account</label>
        <Field label="Rate (blank = default)" hint={`Default ${(Number(settings?.default_admin_fee_rate ?? 0.1) * 100).toFixed(0)}%`}>
          <input inputMode="decimal" placeholder="0.10" value={m.admin_fee_rate ?? ''} onChange={set('admin_fee_rate')} />
        </Field>
        <Field label="Monthly cap (blank = default)" hint={`Default ${money(settings?.default_admin_fee_cap ?? 250)}`}>
          <input inputMode="decimal" placeholder="250.00" value={m.admin_fee_cap ?? ''} onChange={set('admin_fee_cap')} />
        </Field>
        {m.id && <label className="check"><input type="checkbox" checked={m.active !== false} onChange={set('active')} /> Active (inactive missionaries are hidden from gift entry)</label>}
      </div>
      <ErrorBox error={err} />
    </Modal>
  );
}

export default function Missionaries() {
  const { refresh } = useApp();
  const [showInactive, setShowInactive] = useState(false);
  const { data, loading, error, reload } = useRpc<any[]>('list_missionaries', { include_inactive: showInactive });
  const [adding, setAdding] = useState(false);
  const total = (data ?? []).reduce((s, m) => s + Number(m.balance), 0);
  return (
    <div>
      <PageHeader title="Missionaries" subtitle={<>Click a missionary to open their account. Combined balance <strong>{money(total)}</strong>.</>}
        actions={<>
          <label className="check inline"><input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} /> Show inactive</label>
          <button className="btn primary" onClick={() => setAdding(true)}>+ Add missionary</button>
        </>} />
      <ErrorBox error={error} />
      {loading && !data ? <Loading /> : data?.length ? (
        <div className="m-grid">
          {data.map((m) => (
            <button key={m.id} className={`m-card ${m.active ? '' : 'inactive'}`} onClick={() => go(`missionaries/${m.id}`)}>
              <div className="m-photo">
                <Avatar name={m.display_name} url={m.photo_url} size={260} />
              </div>
              <div className="m-body">
                <div className="m-name">{m.display_name}</div>
                <div className="m-role">{m.role_title}{!m.active && ' · inactive'}</div>
                <div className="m-balance"><Money v={m.balance} accounting /></div>
                <div className="m-stats">
                  <span>This month <strong>{money(m.mtd_gifts)}</strong></span>
                  <span>Year to date <strong>{money(m.ytd_gifts)}</strong></span>
                </div>
              </div>
            </button>
          ))}
        </div>
      ) : <Empty>No missionaries yet.</Empty>}
      {adding && <MissionaryForm onClose={() => setAdding(false)} onSaved={(m) => { setAdding(false); refresh(); reload(); go(`missionaries/${m.id}`); }} />}
    </div>
  );
}

const KIND_LABEL: Record<string, string> = {
  gift: 'Gift', admin_fee: 'Admin fee', expense: 'Payment', transfer: 'Transfer', opening: 'Opening balance', void: 'Void', adjustment: 'Adjustment',
};

/** Account statement for any fund; shows the missionary header when the fund belongs to one. */
export function FundAccount({ missionaryId, fundId }: { missionaryId?: string; fundId?: string }) {
  const { refresh } = useApp();
  const [period, setPeriod] = useState<Period>(periods().ytd);
  const [editing, setEditing] = useState(false);
  const [taxInfo, setTaxInfo] = useState(false);
  const params = useMemo(() => ({ missionary_id: missionaryId, fund_id: fundId, from: period.from, to: period.to }), [missionaryId, fundId, period]);
  const { data: a, error, loading, reload } = useRpc<any>('get_fund_account', params);
  const file = useRef<HTMLInputElement>(null);
  if (error) return <ErrorBox error={error} />;
  if (loading && !a) return <Loading />;
  const m = a.missionary;
  const f = a.fund;
  const monthly = a.monthly.map((x: any) => ({ ...x, label: monthLabel(x.month) }));
  const uploadPhoto = async (file: File) => {
    const url = await resizeImage(file);
    await rpc('save_missionary', { ...m, photo_url: url });
    refresh(); reload();
  };

  return (
    <div className="statement">
      <div className="no-print back"><a href={m ? '#/missionaries' : '#/funds'}>← {m ? 'All missionaries' : 'All funds'}</a></div>
      <div className="print-brand"><img src="/bem-logo.jpg" alt="" /><span>{m ? 'Missionary Account Statement' : 'Fund Statement'}</span></div>
      <div className="acct-head">
        {m && (
          <button className="acct-photo" title="Change photo" onClick={() => file.current?.click()}>
            <Avatar name={m.display_name} url={m.photo_url} size={132} />
            <span className="photo-hint no-print">Change photo</span>
            <input ref={file} type="file" accept="image/*" hidden onChange={(e) => { const x = e.target.files?.[0]; if (x) uploadPhoto(x); }} />
          </button>
        )}
        <div className="acct-title">
          <h1>{f.name}</h1>
          <div className="muted">
            {m?.role_title ? `${m.role_title} · ` : ''}Fund {f.code} · {f.restriction === 'with' ? 'With donor restrictions' : 'Without donor restrictions'}
            {f.admin_fee_applies && ` · Admin fee ${(Number(f.effective_fee_rate) * 100).toFixed(0)}% up to ${money(f.effective_fee_cap)}/month`}
          </div>
          {m && (m.email || m.phone) && <div className="muted small">{[m.email, m.phone].filter(Boolean).join(' · ')}</div>}
          {m?.bio && <p className="acct-bio no-print">{m.bio}</p>}
        </div>
        <div className="acct-balance">
          <span className="tile-label">Current balance</span>
          <Money v={a.current_balance} accounting className="big" />
        </div>
      </div>

      <div className="toolbar no-print">
        <PeriodPicker value={period} onChange={setPeriod} />
        <div className="spacer" />
        {m && <button className="btn" onClick={() => setEditing(true)}>Edit details</button>}
        {m && <button className="btn" onClick={() => setTaxInfo(true)}>Tax info (W-9)</button>}
        <a className="btn" href={`#/payments`}>Record a payment</a>
        <button className="btn" onClick={() => window.print()}>Print statement</button>
      </div>
      <div className="print-only print-title">Account statement · {date(a.from)} – {date(a.to)}</div>

      <div className="summary-strip">
        <div><span>Opening {date(a.from)}</span><Money v={a.opening_balance} accounting /></div>
        <div><span>Gifts received</span><Money v={a.totals.gifts} accounting /></div>
        {f.admin_fee_applies || Number(a.totals.admin_fees) ? <div><span>Admin fees</span><Money v={a.totals.admin_fees} accounting /></div> : null}
        <div><span>Payments</span><Money v={a.totals.expenses} accounting /></div>
        {Number(a.totals.transfers) || Number(a.totals.other) ? <div><span>Transfers & other</span><Money v={Number(a.totals.transfers) + Number(a.totals.other)} accounting /></div> : null}
        <div className="strong"><span>Closing {date(a.to)}</span><Money v={a.closing_balance} accounting /></div>
      </div>

      <div className="grid-2 no-print-break">
        <Card title="Last 12 months">
          <Bars data={monthly} series={[{ key: 'gifts', label: 'Gifts', color: 'var(--chart-1)' }, { key: 'expenses', label: 'Payments', color: 'var(--chart-2)' }]} />
        </Card>
        <Card title={`Supporters (${a.donors.length})`}>
          {a.donors.length ? (
            <table className="table compact">
              <tbody>{a.donors.map((d: any) => (
                <tr key={d.donor_id ?? 'anon'}>
                  <td>{d.donor_id ? <a href={`#/donors/${d.donor_id}`}>{d.name}</a> : 'Anonymous'}{d.is_anonymous && <Badge>anonymous</Badge>}<div className="muted small">{d.count} gift{d.count === 1 ? '' : 's'} · last {date(d.last_gift)}</div></td>
                  <td className="num"><Money v={d.total} /></td>
                </tr>
              ))}</tbody>
            </table>
          ) : <Empty>No gifts in this period.</Empty>}
        </Card>
      </div>

      <Card title="Activity">
        {a.rows.length ? (
          <table className="table">
            <thead><tr><th>Date</th><th>Type</th><th>Description</th><th className="num">In</th><th className="num">Out</th><th className="num">Balance</th></tr></thead>
            <tbody>
              <tr className="subtotal"><td>{date(a.from)}</td><td /><td>Opening balance</td><td /><td /><td className="num"><Money v={a.opening_balance} accounting /></td></tr>
              {(() => {
                let bal = Number(a.opening_balance);
                return a.rows.map((r: any) => {
                  bal += Number(r.amount);
                  return (
                    <tr key={r.entry_id} className={r.kind === 'void' ? 'void-row' : ''}>
                      <td className="nowrap">{date(r.entry_date)}</td>
                      <td><span className={`kind ${r.kind}`}>{KIND_LABEL[r.kind] ?? r.kind}</span></td>
                      <td>{r.description}{r.detail && <div className="muted small">{r.detail}</div>}</td>
                      <td className="num">{Number(r.amount) > 0 ? money(r.amount) : ''}</td>
                      <td className="num">{Number(r.amount) < 0 ? money(-r.amount) : ''}</td>
                      <td className="num"><Money v={bal} accounting /></td>
                    </tr>
                  );
                });
              })()}
            </tbody>
            <tfoot><tr className="total"><td colSpan={5}>Closing balance</td><td className="num"><Money v={a.closing_balance} accounting /></td></tr></tfoot>
          </table>
        ) : <Empty>No activity in this period.</Empty>}
      </Card>
      {taxInfo && m && <PayeeForm missionaryId={m.id} onClose={() => setTaxInfo(false)} onSaved={() => setTaxInfo(false)} />}
      {editing && m && (
        <MissionaryForm initial={{ ...m, admin_fee_applies: f.admin_fee_applies, admin_fee_rate: f.admin_fee_rate ?? '', admin_fee_cap: f.admin_fee_cap ?? '' }}
          onClose={() => setEditing(false)} onSaved={() => { setEditing(false); refresh(); reload(); }} />
      )}
    </div>
  );
}
