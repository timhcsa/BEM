import React, { useState } from 'react';
import { rpc } from '../lib/api';
import { go, useApp, type Fund } from '../lib/store';
import { money } from '../lib/format';
import { Badge, Card, ErrorBox, Field, Modal, Money, PageHeader } from '../components/ui';

const KIND: Record<string, string> = { general: 'General', conference: 'Conference', missionary: 'Missionary', other: 'Project / designated' };

function FundForm({ initial, onClose, onSaved }: { initial?: Partial<Fund>; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<any>({ kind: 'other', restriction: 'with', admin_fee_applies: false, active: true, sort: 100, ...(initial ?? {}) });
  const [err, setErr] = useState<string | null>(null);
  const set = (k: string) => (e: any) => setF({ ...f, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value });
  return (
    <Modal title={f.id ? `Edit ${f.name}` : 'New project fund'} onClose={onClose}
      footer={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={async () => {
        try { await rpc('save_fund', f); onSaved(); } catch (e: any) { setErr(e.message); }
      }}>Save</button></>}>
      {!f.id && <p className="muted small">A project fund (a building project, a mission trip, a relief effort…) shows up right away in the fund list when entering gifts and payments, and gets its own statement.</p>}
      {f.kind === 'missionary' && <p className="muted">Missionary funds are created and named from the Missionaries page.</p>}
      <div className="form-grid">
        <Field label="Code"><input value={f.code ?? ''} onChange={set('code')} placeholder="e.g. HAITI26" /></Field>
        <Field label="Name"><input value={f.name ?? ''} onChange={set('name')} /></Field>
        {!f.is_system && f.kind !== 'missionary' && (
          <Field label="Type"><select value={f.kind} onChange={set('kind')}>
            <option value="other">Project / designated</option><option value="conference">Conference</option></select></Field>
        )}
        <Field label="Net asset class" hint="Gifts a donor designates for a purpose are usually “with donor restrictions”. Confirm with your CPA.">
          <select value={f.restriction} onChange={set('restriction')}>
            <option value="without">Without donor restrictions</option>
            <option value="with">With donor restrictions</option>
          </select>
        </Field>
        <Field label="Description" wide><input value={f.description ?? ''} onChange={set('description')} /></Field>
        <Field label="Display order"><input type="number" value={f.sort ?? 100} onChange={set('sort')} /></Field>
        {f.kind !== 'general' && <label className="check"><input type="checkbox" checked={!!f.admin_fee_applies} onChange={set('admin_fee_applies')} /> Charge the administrative fee</label>}
        {!f.is_system && <label className="check"><input type="checkbox" checked={f.active !== false} onChange={set('active')} /> Active</label>}
      </div>
      <ErrorBox error={err} />
    </Modal>
  );
}

export default function Funds() {
  const { lookups, refresh } = useApp();
  const [editing, setEditing] = useState<Partial<Fund> | null>(null);
  const funds = lookups?.funds ?? [];
  const total = funds.reduce((s, f) => s + Number(f.balance), 0);
  const groups: [string, Fund[]][] = [
    ['Ministry funds', funds.filter((f) => f.kind === 'general' || f.kind === 'conference')],
    ['Project & designated funds', funds.filter((f) => f.kind === 'other')],
    ['Missionary accounts', funds.filter((f) => f.kind === 'missionary')],
  ];
  return (
    <div>
      <PageHeader title="Funds" subtitle="Each fund is its own set of books. Together they add up to the money in the bank (plus undeposited gifts)."
        actions={<button className="btn primary" onClick={() => setEditing({})}>+ New project fund</button>} />
      <Card>
        <table className="table">
          <thead><tr><th>Code</th><th>Fund</th><th>Type</th><th>Net asset class</th><th>Admin fee</th><th className="num">Balance</th><th /></tr></thead>
          {groups.filter(([, fs]) => fs.length).map(([label, fs]) => (
            <tbody key={label}>
              <tr className="group-row"><td colSpan={7}>{label}</td></tr>
              {fs.map((f) => (
                <tr key={f.id} className={`clickable ${f.active ? '' : 'void'}`} onClick={() => go(f.missionary_id ? `missionaries/${f.missionary_id}` : `funds/${f.id}`)}>
                  <td className="muted">{f.code}</td>
                  <td>{f.name} {!f.active && <Badge>inactive</Badge>}</td>
                  <td>{KIND[f.kind]}</td>
                  <td>{f.restriction === 'with' ? 'With restrictions' : 'Without restrictions'}</td>
                  <td className="small">{f.admin_fee_applies ? `${(f.effective_fee_rate * 100).toFixed(0)}% to ${money(f.effective_fee_cap)}/mo` : '—'}</td>
                  <td className="num"><Money v={f.balance} accounting /></td>
                  <td><button className="btn small" onClick={(e) => { e.stopPropagation(); setEditing(f); }}>Edit</button></td>
                </tr>
              ))}
            </tbody>
          ))}
          <tfoot><tr className="total"><td colSpan={5}>Total of all funds</td><td className="num"><Money v={total} accounting /></td><td /></tr></tfoot>
        </table>
      </Card>
      {editing && <FundForm initial={editing} onClose={() => setEditing(null)} onSaved={() => { setEditing(null); refresh(); }} />}
    </div>
  );
}
