import React, { useEffect, useRef, useState } from 'react';
import { rpc } from '../lib/api';
import { DONOR_TYPES, date, money } from '../lib/format';
import { ErrorBox, Field, Modal, useClickOutside, useDebounced } from './ui';

export type Donor = Record<string, any>;

const EMPTY: Donor = { donor_type: 'household', receipt_preference: 'email', country: 'US', active: true };

export function DonorForm({ initial, onSaved, onCancel }: { initial?: Donor | null; onSaved: (d: Donor) => void; onCancel: () => void }) {
  const [d, setD] = useState<Donor>(initial ?? EMPTY);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) =>
    setD({ ...d, [k]: e.target.type === 'checkbox' ? (e.target as HTMLInputElement).checked : e.target.value });
  const person = d.donor_type === 'individual' || d.donor_type === 'household';
  const save = async () => {
    setBusy(true); setErr(null);
    try { onSaved(await rpc('save_donor', d)); } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };
  return (
    <Modal title={d.id ? `Edit donor #${d.donor_number}` : 'New donor'} onClose={onCancel} size="lg"
      footer={<><button className="btn" onClick={onCancel}>Cancel</button><button className="btn primary" disabled={busy} onClick={save}>Save donor</button></>}>
      <div className="form-grid">
        <Field label="Donor type">
          <select value={d.donor_type} onChange={set('donor_type')}>
            {Object.entries(DONOR_TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
        {person ? (
          <>
            <Field label="First name"><input autoFocus value={d.first_name ?? ''} onChange={set('first_name')} /></Field>
            {d.donor_type === 'household' && <Field label="Spouse first name"><input value={d.spouse_name ?? ''} onChange={set('spouse_name')} /></Field>}
            <Field label="Last name"><input value={d.last_name ?? ''} onChange={set('last_name')} /></Field>
          </>
        ) : (
          <>
            <Field label="Organization name" wide><input autoFocus value={d.organization_name ?? ''} onChange={set('organization_name')} /></Field>
            <Field label="Contact person"><input value={d.contact_name ?? ''} onChange={set('contact_name')} placeholder="Pastor, treasurer…" /></Field>
          </>
        )}
        <Field label="Salutation" hint="Used on giving statements, e.g. “Dear Bob and Mary”"><input value={d.salutation ?? ''} onChange={set('salutation')} /></Field>
        <Field label="Email"><input type="email" value={d.email ?? ''} onChange={set('email')} /></Field>
        <Field label="Phone"><input value={d.phone ?? ''} onChange={set('phone')} /></Field>
        <Field label="Address" wide><input value={d.address_line1 ?? ''} onChange={set('address_line1')} /></Field>
        <Field label="Address line 2" wide><input value={d.address_line2 ?? ''} onChange={set('address_line2')} /></Field>
        <Field label="City"><input value={d.city ?? ''} onChange={set('city')} /></Field>
        <Field label="State"><input value={d.state ?? ''} onChange={set('state')} maxLength={20} /></Field>
        <Field label="ZIP"><input value={d.postal_code ?? ''} onChange={set('postal_code')} /></Field>
        {person && <Field label="Home church"><input value={d.church_affiliation ?? ''} onChange={set('church_affiliation')} /></Field>}
        <Field label="Send receipts by">
          <select value={d.receipt_preference} onChange={set('receipt_preference')}>
            <option value="email">Email</option><option value="mail">Mail</option><option value="none">Don't send</option>
          </select>
        </Field>
        <Field label="Notes" wide><textarea rows={2} value={d.notes ?? ''} onChange={set('notes')} /></Field>
        <label className="check"><input type="checkbox" checked={!!d.is_anonymous} onChange={set('is_anonymous')} /> Wishes to remain anonymous (hidden from missionary statements)</label>
        {d.id && <label className="check"><input type="checkbox" checked={d.active !== false} onChange={set('active')} /> Active</label>}
      </div>
      <ErrorBox error={err} />
    </Modal>
  );
}

/** Type-ahead donor search with "new donor" shortcut. */
export function DonorPicker({ value, onChange, autoFocus }: { value: Donor | null; onChange: (d: Donor | null) => void; autoFocus?: boolean }) {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [results, setResults] = useState<Donor[]>([]);
  const [hi, setHi] = useState(0);
  const [creating, setCreating] = useState(false);
  const dq = useDebounced(q, 150);
  const box = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);
  useClickOutside(box, () => setOpen(false));

  useEffect(() => {
    if (!open) return;
    rpc<Donor[]>('search_donors', { q: dq, limit: 12 }).then((r) => { setResults(r); setHi(0); }).catch(() => setResults([]));
  }, [dq, open]);

  useEffect(() => { if (autoFocus && !value) input.current?.focus(); }, [autoFocus, value]);

  if (value) {
    return (
      <div className="donor-chosen">
        <div>
          <strong>{value.display_name}</strong> <span className="muted">#{value.donor_number}</span>
          <div className="muted small">{[value.city, value.state].filter(Boolean).join(', ')}{value.email ? ` · ${value.email}` : ''}</div>
        </div>
        <button type="button" className="btn small" onClick={() => { onChange(null); setQ(''); setTimeout(() => input.current?.focus(), 0); }}>Change</button>
      </div>
    );
  }
  const pick = (d: Donor) => { onChange(d); setOpen(false); setQ(''); };
  return (
    <div className="donor-picker" ref={box}>
      <input ref={input} value={q} placeholder="Search donors by name, email, city or #…" onClick={() => setOpen(true)}
        onChange={(e) => { setQ(e.target.value); setOpen(true); }}
        onKeyDown={(e) => {
          if (e.key === 'ArrowDown') { e.preventDefault(); setHi((h) => Math.min(h + 1, results.length)); }
          if (e.key === 'ArrowUp') { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); }
          if (e.key === 'Enter') { e.preventDefault(); if (hi < results.length && results[hi]) pick(results[hi]); else setCreating(true); }
        }} />
      {open && (
        <div className="dropdown">
          {results.map((d, i) => (
            <button type="button" key={d.id} className={i === hi ? 'hi' : ''} onMouseEnter={() => setHi(i)} onClick={() => pick(d)}>
              <span><strong>{d.display_name}</strong> <span className="muted">#{d.donor_number}</span></span>
              <span className="muted small">{[d.city, d.state].filter(Boolean).join(', ')}{d.last_gift_date ? ` · last gift ${date(d.last_gift_date)}` : ''}{Number(d.ytd_total) ? ` · ${money(d.ytd_total)} this year` : ''}</span>
            </button>
          ))}
          {!results.length && <div className="muted pad">No donors match “{q}”.</div>}
          <button type="button" className={`new ${hi === results.length ? 'hi' : ''}`} onClick={() => setCreating(true)}>+ Add a new donor{q ? ` “${q}”` : ''}</button>
        </div>
      )}
      {creating && (
        <DonorForm initial={guessDonor(q)} onCancel={() => setCreating(false)} onSaved={(d) => { setCreating(false); pick(d); }} />
      )}
    </div>
  );
}

function guessDonor(q: string): Donor {
  const t = q.trim();
  if (!t) return { ...EMPTY };
  if (/church|baptist|chapel|ministr|fellowship|foundation|inc\b|llc/i.test(t)) {
    return { ...EMPTY, donor_type: /foundation/i.test(t) ? 'foundation' : 'church', organization_name: t };
  }
  const parts = t.split(/\s+/);
  return parts.length > 1
    ? { ...EMPTY, first_name: parts.slice(0, -1).join(' '), last_name: parts[parts.length - 1] }
    : { ...EMPTY, last_name: t };
}
