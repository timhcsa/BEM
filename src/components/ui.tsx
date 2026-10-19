import React, { useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { acct, money, initials, periods, type Period } from '../lib/format';
import type { Fund } from '../lib/store';

export function Money({ v, accounting = false, className = '' }: { v: unknown; accounting?: boolean; className?: string }) {
  const n = Number(v ?? 0);
  return <span className={`money ${n < 0 ? 'neg' : ''} ${className}`}>{accounting ? acct(n) : money(n)}</span>;
}

export function PageHeader({ title, subtitle, actions }: { title: React.ReactNode; subtitle?: React.ReactNode; actions?: React.ReactNode }) {
  return (
    <div className="page-header">
      <div>
        <h1>{title}</h1>
        {subtitle && <p className="subtitle">{subtitle}</p>}
      </div>
      {actions && <div className="actions no-print">{actions}</div>}
    </div>
  );
}

export function Card({ title, actions, children, className = '' }: { title?: React.ReactNode; actions?: React.ReactNode; children: React.ReactNode; className?: string }) {
  return (
    <section className={`card ${className}`}>
      {(title || actions) && (
        <div className="card-head">
          {title && <h2>{title}</h2>}
          {actions && <div className="no-print">{actions}</div>}
        </div>
      )}
      {children}
    </section>
  );
}

export function Field({ label, children, hint, wide = false }: { label: string; children: React.ReactNode; hint?: React.ReactNode; wide?: boolean }) {
  return (
    <label className={`field ${wide ? 'wide' : ''}`}>
      <span className="label">{label}</span>
      {children}
      {hint && <span className="hint">{hint}</span>}
    </label>
  );
}

export function Modal({ title, onClose, children, footer, size = 'md' }: { title: React.ReactNode; onClose: () => void; children: React.ReactNode; footer?: React.ReactNode; size?: 'sm' | 'md' | 'lg' }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  return createPortal(
    <div className="modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`modal ${size}`} role="dialog" aria-modal="true">
        <div className="modal-head">
          <h2>{title}</h2>
          <button className="icon-btn" onClick={onClose} aria-label="Close">×</button>
        </div>
        <div className="modal-body">{children}</div>
        {footer && <div className="modal-foot">{footer}</div>}
      </div>
    </div>,
    document.body,
  );
}

export function Empty({ children }: { children: React.ReactNode }) {
  return <div className="empty">{children}</div>;
}

export function Loading() {
  return <div className="loading">Loading…</div>;
}

export function ErrorBox({ error }: { error: string | null }) {
  if (!error) return null;
  return <div className="error-box">{error}</div>;
}

export function Badge({ children, tone = 'neutral' }: { children: React.ReactNode; tone?: 'neutral' | 'good' | 'warn' | 'bad' | 'info' }) {
  return <span className={`badge ${tone}`}>{children}</span>;
}

export function Avatar({ name, url, size = 48 }: { name: string; url?: string | null; size?: number }) {
  const [broken, setBroken] = useState(false);
  if (url && !broken) {
    return <img className="avatar" src={url} alt={name} width={size} height={size} style={{ width: size, height: size }} onError={() => setBroken(true)} />;
  }
  return <span className="avatar placeholder" style={{ width: size, height: size, fontSize: size * 0.36 }}>{initials(name)}</span>;
}

/** Fund dropdown grouped by type. */
export function FundSelect({ funds, value, onChange, includeInactive = false, placeholder = 'Choose a fund…', autoFocus = false }:
  { funds: Fund[]; value: string; onChange: (id: string) => void; includeInactive?: boolean; placeholder?: string; autoFocus?: boolean }) {
  const list = funds.filter((f) => includeInactive || f.active || f.id === value);
  const groups: [string, Fund[]][] = [
    ['Ministry funds', list.filter((f) => f.kind === 'general' || f.kind === 'conference')],
    ['Missionary accounts', list.filter((f) => f.kind === 'missionary')],
    ['Other designated funds', list.filter((f) => f.kind === 'other')],
  ];
  return (
    <select value={value} onChange={(e) => onChange(e.target.value)} autoFocus={autoFocus}>
      <option value="">{placeholder}</option>
      {groups.filter(([, fs]) => fs.length).map(([label, fs]) => (
        <optgroup key={label} label={label}>
          {fs.map((f) => <option key={f.id} value={f.id}>{f.name}{f.active ? '' : ' (inactive)'}</option>)}
        </optgroup>
      ))}
    </select>
  );
}

export function PeriodPicker({ value, onChange }: { value: Period; onChange: (p: Period) => void }) {
  const ps = periods();
  const key = Object.entries(ps).find(([, p]) => p.from === value.from && p.to === value.to)?.[0] ?? 'custom';
  return (
    <div className="period-picker no-print">
      <select value={key} onChange={(e) => { const p = ps[e.target.value]; if (p) onChange(p); }}>
        {Object.entries(ps).map(([k, p]) => <option key={k} value={k}>{p.label}</option>)}
        <option value="custom">Custom dates</option>
      </select>
      <input type="date" value={value.from} onChange={(e) => onChange({ ...value, from: e.target.value, label: 'Custom' })} />
      <span>to</span>
      <input type="date" value={value.to} onChange={(e) => onChange({ ...value, to: e.target.value, label: 'Custom' })} />
    </div>
  );
}

/** Ask for a reason, then void. */
export function VoidButton({ what, onVoid, disabled, disabledReason }: { what: string; onVoid: (reason: string) => Promise<void>; disabled?: boolean; disabledReason?: string }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  return (
    <>
      <button className="btn danger-outline" disabled={disabled} title={disabled ? disabledReason : undefined} onClick={() => setOpen(true)}>Void {what}</button>
      {open && (
        <Modal title={`Void ${what}`} size="sm" onClose={() => setOpen(false)}
          footer={<>
            <button className="btn" onClick={() => setOpen(false)}>Cancel</button>
            <button className="btn danger" disabled={busy || !reason.trim()} onClick={async () => {
              setBusy(true); setErr(null);
              try { await onVoid(reason.trim()); setOpen(false); } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
            }}>Void</button>
          </>}>
          <p>Voiding keeps the original record and posts an exact reversing entry, so the audit trail stays complete.</p>
          <Field label="Reason (required)">
            <input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. entered twice, returned check" />
          </Field>
          <ErrorBox error={err} />
        </Modal>
      )}
    </>
  );
}

/** Text input that only accepts money. */
export function MoneyInput({ value, onChange, autoFocus, placeholder = '0.00', inputRef }:
  { value: string; onChange: (v: string) => void; autoFocus?: boolean; placeholder?: string; inputRef?: React.Ref<HTMLInputElement> }) {
  return (
    <div className="money-input">
      <span>$</span>
      <input ref={inputRef} inputMode="decimal" value={value} autoFocus={autoFocus} placeholder={placeholder}
        onChange={(e) => onChange(e.target.value.replace(/[^0-9.,-]/g, ''))} />
    </div>
  );
}

export function useDebounced<T>(value: T, ms = 250): T {
  const [v, setV] = useState(value);
  useEffect(() => { const t = setTimeout(() => setV(value), ms); return () => clearTimeout(t); }, [value, ms]);
  return v;
}

export function useClickOutside(ref: React.RefObject<HTMLElement>, fn: () => void) {
  useEffect(() => {
    const h = (e: MouseEvent) => { if (ref.current && !ref.current.contains(e.target as Node)) fn(); };
    document.addEventListener('mousedown', h);
    return () => document.removeEventListener('mousedown', h);
  }, [ref, fn]);
}

export function Bars({ data, series }: { data: Record<string, any>[]; series: { key: string; label: string; color: string }[] }) {
  // Simple grouped bar chart in SVG (no chart library needed).
  const max = Math.max(1, ...data.flatMap((d) => series.map((s) => Number(d[s.key] || 0))));
  const W = 640, H = 180, pad = 24, gw = (W - pad) / Math.max(1, data.length), bw = Math.max(4, (gw - 10) / series.length);
  const ref = useRef<SVGSVGElement>(null);
  const [tip, setTip] = useState<string | null>(null);
  return (
    <div className="bars">
      <svg ref={ref} viewBox={`0 0 ${W} ${H + 22}`} role="img" aria-label="Monthly chart">
        {[0.25, 0.5, 0.75, 1].map((t) => (
          <line key={t} x1={pad} x2={W} y1={H - H * t * 0.92} y2={H - H * t * 0.92} className="gridline" />
        ))}
        {data.map((d, i) => (
          <g key={i} transform={`translate(${pad + i * gw + 5},0)`}>
            {series.map((s, j) => {
              const h = (Number(d[s.key] || 0) / max) * H * 0.92;
              return <rect key={s.key} x={j * bw} y={H - h} width={bw - 2} height={h} fill={s.color} rx={2}
                onMouseEnter={() => setTip(`${d.label}: ${s.label} ${money(d[s.key])}`)} onMouseLeave={() => setTip(null)} />;
            })}
            <text x={(gw - 10) / 2} y={H + 16} textAnchor="middle" className="axis">{d.label}</text>
          </g>
        ))}
      </svg>
      <div className="legend">
        {series.map((s) => <span key={s.key}><i style={{ background: s.color }} />{s.label}</span>)}
        {tip && <span className="tip">{tip}</span>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------
// Tax treatment of a line paid to a missionary (drives the 1099).
// ---------------------------------------------------------------------
export const TAX_TREATMENTS: Record<string, string> = {
  taxable: 'Taxable (salary / personal)',
  reimbursement: 'Non-taxable reimbursement',
  housing: 'Housing allowance',
};
export const TAX_SHORT: Record<string, string> = { taxable: 'Taxable', reimbursement: 'Non-taxable reimbursement', housing: 'Housing allowance' };

export function defaultTaxTreatment(account?: { code: string; tax_form?: string | null } | null): string {
  if (!account) return 'taxable';
  if (account.code === '5010') return 'housing';
  if ((account as any).tax_form === 'nec1') return 'taxable';
  return 'reimbursement';
}

export function TaxTreatmentSelect({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <select className={`tax-select ${value}`} value={value} onChange={(e) => onChange(e.target.value)}
      title="Taxable: salary or extra funds for personal use, reported on the 1099. Non-taxable: business expenses repaid with receipts, not reported. Housing allowance: board-designated, not in 1099 box 1.">
      {Object.entries(TAX_TREATMENTS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
    </select>
  );
}
