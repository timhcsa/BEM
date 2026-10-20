import React, { useState } from 'react';
import { rpc } from '../lib/api';
import { useApp, useRpc } from '../lib/store';
import { date } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, Loading, Modal, Money, PageHeader, useDebounced } from '../components/ui';

/** Edit a payee's tax (W-9) information. Pass id, or missionaryId to edit a missionary's payee. */
export function PayeeForm({ id, missionaryId, onClose, onSaved }: { id?: string; missionaryId?: string; onClose: () => void; onSaved: () => void }) {
  const { toast } = useApp();
  const { data } = useRpc<any>(id || missionaryId ? 'get_payee' : 'list_payees', id ? { id } : missionaryId ? { missionary_id: missionaryId } : { q: '__none__' });
  const [p, setP] = useState<any>(null);
  const [tinEdit, setTinEdit] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const cur = p ?? (id || missionaryId ? data : { is_1099: false, worker_type: 'vendor', tin_type: 'ssn', active: true });
  if ((id || missionaryId) && !cur) return null;
  const set = (k: string) => (e: any) => {
    const v = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    const n = { ...cur, [k]: v };
    if (k === 'worker_type') n.is_1099 = v === 'contractor';
    setP(n);
  };
  const employee = cur.worker_type === 'employee';
  const hasStoredTin = !!cur.tin_formatted;
  return (
    <Modal title={cur.id ? `Tax information: ${cur.display_name}` : 'New payee'} onClose={onClose} size="lg"
      footer={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={async () => {
        setErr(null);
        const body: any = { ...cur };
        delete body.tin_formatted;
        if (hasStoredTin && !tinEdit) delete body.tin;   // keep the stored number
        try { await rpc('save_payee', body); toast('Payee saved'); onSaved(); } catch (e: any) { setErr(e.message); }
      }}>Save</button></>}>
      {cur.missionary_name && <p className="muted">Missionary: {cur.missionary_name}. Missionaries are BEM employees: their salary and housing allowance go on a W-2 (see Reports › W-2 worksheet), not a 1099. Keep their SSN and address here for payroll.</p>}
      <div className="form-grid">
        <Field label="Name on payments"><input value={cur.display_name ?? ''} onChange={set('display_name')} disabled={!!cur.missionary_id} /></Field>
        <Field label="Legal name (W-9 line 1)"><input value={cur.legal_name ?? ''} onChange={set('legal_name')} placeholder="e.g. Ted Sutherland" /></Field>
        <Field label="Business name (W-9 line 2, optional)"><input value={cur.business_name ?? ''} onChange={set('business_name')} /></Field>
        <Field label="Taxpayer ID type">
          <select value={cur.tin_type ?? ''} onChange={set('tin_type')}>
            <option value="">—</option><option value="ssn">SSN (individual)</option><option value="ein">EIN (business)</option>
          </select>
        </Field>
        <Field label="Taxpayer ID number" hint="Stored for 1099 filing; shown masked everywhere else.">
          {hasStoredTin && !tinEdit
            ? <div className="tin-row"><span>{cur.tin_type === 'ein' ? 'XX-XXX' : 'XXX-XX-'}{String(cur.tin_formatted).slice(-4)}</span><button className="btn small" onClick={() => { setTinEdit(true); setP({ ...cur, tin: '' }); }}>Change</button></div>
            : <input value={cur.tin ?? ''} onChange={set('tin')} placeholder={cur.tin_type === 'ein' ? '12-3456789' : '123-45-6789'} autoComplete="off" />}
        </Field>
        <Field label="Email (for sending their copy)"><input value={cur.email ?? ''} onChange={set('email')} /></Field>
        <Field label="Address" wide><input value={cur.address_line1 ?? ''} onChange={set('address_line1')} /></Field>
        <Field label="Address 2" wide><input value={cur.address_line2 ?? ''} onChange={set('address_line2')} /></Field>
        <Field label="City"><input value={cur.city ?? ''} onChange={set('city')} /></Field>
        <Field label="State"><input value={cur.state ?? ''} onChange={set('state')} maxLength={2} /></Field>
        <Field label="ZIP"><input value={cur.postal_code ?? ''} onChange={set('postal_code')} /></Field>
        <Field label="Relationship to BEM">
          <select value={cur.worker_type ?? 'vendor'} onChange={set('worker_type')} disabled={!!cur.missionary_id}>
            <option value="employee">Employee (W-2): missionaries, staff</option>
            <option value="contractor">Independent contractor (1099-NEC)</option>
            <option value="vendor">Vendor / business</option>
          </select>
        </Field>
        <label className="check"><input type="checkbox" checked={!employee && !!cur.is_1099} disabled={employee} onChange={set('is_1099')} /> Receives a Form 1099 (contractor, landlord, attorney…){employee && <span className="muted small"> · employees get a W-2 instead</span>}</label>
        <label className="check"><input type="checkbox" checked={!!cur.w9_on_file} onChange={set('w9_on_file')} /> Signed Form W-9 on file</label>
        <Field label="Notes" wide><input value={cur.notes ?? ''} onChange={set('notes')} /></Field>
        {cur.id && !cur.missionary_id && <label className="check"><input type="checkbox" checked={cur.active !== false} onChange={set('active')} /> Active</label>}
      </div>
      <ErrorBox error={err} />
    </Modal>
  );
}

export default function Payees() {
  const [q, setQ] = useState('');
  const dq = useDebounced(q);
  const { data, loading, error, reload } = useRpc<any[]>('list_payees', { q: dq, include_inactive: true });
  const [open, setOpen] = useState<string | 'new' | null>(null);
  const rows = data ?? [];
  return (
    <div>
      <PageHeader title="Payees" subtitle="Everyone BEM pays. Mark employees (W-2), contractors (1099) and vendors and keep their W-9 information here."
        actions={<>
          <a className="btn" href="#/reports/1099">Year-end 1099s →</a>
          <button className="btn primary" onClick={() => setOpen('new')}>+ New payee</button>
        </>} />
      <div className="filters no-print"><input type="search" placeholder="Search payees" value={q} onChange={(e) => setQ(e.target.value)} style={{ minWidth: 300 }} /></div>
      <ErrorBox error={error} />
      <Card>
        {loading && !data ? <Loading /> : rows.length ? (
          <table className="table">
            <thead><tr><th>Payee</th><th>Legal name</th><th>Type</th><th>1099</th><th>Taxpayer ID</th><th>W-9</th><th>Last paid</th><th className="num">Paid this year</th></tr></thead>
            <tbody>{rows.map((p) => (
              <tr key={p.id} className={`clickable ${p.active ? '' : 'void'}`} onClick={() => setOpen(p.id)}>
                <td>{p.display_name}{p.missionary_name && <div className="muted small">Missionary</div>}</td>
                <td>{p.legal_name ?? <span className="muted">—</span>}</td>
                <td className="small">{p.worker_type === 'employee' ? 'Employee (W-2)' : p.worker_type === 'contractor' ? 'Contractor' : 'Vendor'}</td>
                <td>{p.is_1099 ? <Badge tone="info">1099</Badge> : <span className="muted small">no</span>}</td>
                <td className="small">{p.tin_masked ?? (p.is_1099 ? <Badge tone="warn">missing</Badge> : '—')}</td>
                <td>{p.w9_on_file ? <Badge tone="good">✓</Badge> : p.is_1099 ? <Badge tone="warn">needed</Badge> : ''}</td>
                <td className="small nowrap">{date(p.last_paid)}</td>
                <td className="num"><Money v={p.ytd_paid} /></td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>No payees yet. They're created automatically when you record a payment.</Empty>}
      </Card>
      {open && <PayeeForm id={open === 'new' ? undefined : open} onClose={() => setOpen(null)} onSaved={() => { setOpen(null); reload(); }} />}
    </div>
  );
}
