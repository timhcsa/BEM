import React, { useMemo, useState } from 'react';
import { rpc } from '../lib/api';
import { DONOR_EXPORT_COLUMNS, DONOR_FIELDS, autoMap, parseCsv, toDonor } from '../lib/csv';
import { download, toCsv } from '../lib/format';
import { Badge, ErrorBox, Modal } from './ui';

type Result = { created: number; updated: number; skipped: number; errors: number; results: any[] };

export function downloadDonorTemplate() {
  const sample = [{ donor_type: 'household', first_name: 'Robert', spouse_name: 'Linda', last_name: 'Anderson', email: 'randerson@example.com',
    address_line1: '112 Maple St', city: 'Goshen', state: 'IN', postal_code: '46526', receipt_preference: 'email' },
  { donor_type: 'church', organization_name: 'Grace Baptist Church', contact_name: 'Pastor Mark Ellis', address_line1: '400 Main St',
    city: 'Kokomo', state: 'IN', postal_code: '46901', receipt_preference: 'mail' }];
  download('donor-import-template.csv', toCsv(sample, DONOR_EXPORT_COLUMNS), 'text/csv');
}

export default function DonorImport({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [fileName, setFileName] = useState('');
  const [grid, setGrid] = useState<string[][] | null>(null);
  const [map, setMap] = useState<string[]>([]);
  const [mode, setMode] = useState<'skip' | 'update'>('skip');
  const [preview, setPreview] = useState<Result | null>(null);
  const [done, setDone] = useState<Result | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const headers = grid?.[0] ?? [];
  const body = grid?.slice(1) ?? [];
  const donors = useMemo(() => body.map((r) => {
    const raw: Record<string, string> = {};
    map.forEach((f, i) => { if (f) raw[f] = r[i] ?? ''; });
    return toDonor(raw);
  }), [grid, map]);

  const load = async (f: File) => {
    setErr(null); setPreview(null); setDone(null);
    const text = await f.text();
    const g = parseCsv(text);
    if (g.length < 2) { setErr('That file has no data rows.'); return; }
    setFileName(f.name); setGrid(g); setMap(autoMap(g[0]));
  };

  const run = async (dry: boolean) => {
    setBusy(true); setErr(null);
    try {
      const r = await rpc<Result>('import_donors', { rows: donors, mode, dry_run: dry });
      if (dry) setPreview(r); else { setDone(r); onDone(); }
    } catch (e: any) { setErr(e.message); } finally { setBusy(false); }
  };

  const mappedNames = map.includes('first_name') || map.includes('last_name') || map.includes('organization_name') || map.includes('full_name');
  const tone = (a: string) => (a === 'create' ? 'good' : a === 'update' ? 'info' : a === 'error' ? 'bad' : 'neutral') as any;
  const label: Record<string, string> = { create: 'New', update: 'Update', skip: 'Skip', error: 'Error' };

  return (
    <Modal title="Import donors from a CSV file" onClose={onClose} size="lg"
      footer={done ? <button className="btn primary" onClick={onClose}>Done</button> : <>
        <button className="btn" onClick={onClose}>Cancel</button>
        {grid && <button className="btn" disabled={busy || !mappedNames} onClick={() => run(true)}>{preview ? 'Check again' : 'Check the file'}</button>}
        {preview && <button className="btn primary" disabled={busy || (preview.created + preview.updated === 0)} onClick={() => run(false)}>
          Import {preview.created} new{mode === 'update' ? `, update ${preview.updated}` : ''}</button>}
      </>}>
      {done ? (
        <div>
          <p className="big-total">Import finished</p>
          <p>{done.created} donors added · {done.updated} updated · {done.skipped} skipped · {done.errors} with errors.</p>
          {done.errors > 0 && <ResultTable rows={done.results.filter((r) => r.action === 'error')} tone={tone} label={label} donors={donors} />}
        </div>
      ) : (
        <>
          <ol className="steps">
            <li>Save your spreadsheet as <strong>CSV</strong> (in Excel or Numbers: File → Export/Save As → CSV). One donor per row, with column names in the first row.
              {' '}<button className="linklike" onClick={downloadDonorTemplate}>Download a template</button>.</li>
            <li>Choose the file, check that each column is matched to the right field, then click <strong>Check the file</strong>.</li>
            <li>Nothing is saved until you click <strong>Import</strong>.</li>
          </ol>
          <input type="file" accept=".csv,text/csv,.txt" onChange={(e) => { const f = e.target.files?.[0]; if (f) load(f); }} />
          {grid && (
            <>
              <h3 className="section-label">{fileName}: {body.length} rows · match the columns</h3>
              <div className="map-grid">
                {headers.map((h, i) => (
                  <label key={i} className="map-row">
                    <span className="map-col"><strong>{h || `Column ${i + 1}`}</strong><span className="muted small">{body.slice(0, 2).map((r) => r[i]).filter(Boolean).join(' · ')}</span></span>
                    <span className="map-arrow">→</span>
                    <select value={map[i] ?? ''} onChange={(e) => { const m = [...map]; m[i] = e.target.value; setMap(m); setPreview(null); }}>
                      <option value="">— Don't import —</option>
                      {DONOR_FIELDS.map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                    </select>
                  </label>
                ))}
              </div>
              {!mappedNames && <ErrorBox error="Match at least one name column (first/last name, full name or organization name)." />}
              <h3 className="section-label">If a donor already exists</h3>
              <div className="radio-row">
                <label className="check inline"><input type="radio" checked={mode === 'skip'} onChange={() => { setMode('skip'); setPreview(null); }} /> Skip them (only add new donors)</label>
                <label className="check inline"><input type="radio" checked={mode === 'update'} onChange={() => { setMode('update'); setPreview(null); }} /> Update them with the file's information</label>
              </div>
              <p className="muted small">Existing donors are recognized by donor #, then email, then name + ZIP. Gifts are never imported or changed.</p>
            </>
          )}
          <ErrorBox error={err} />
          {preview && (
            <>
              <div className="import-summary">
                <span><Badge tone="good">{preview.created} new</Badge></span>
                <span><Badge tone="info">{preview.updated} to update</Badge></span>
                <span><Badge>{preview.skipped} skipped</Badge></span>
                <span><Badge tone="bad">{preview.errors} errors</Badge></span>
              </div>
              <ResultTable rows={preview.results} tone={tone} label={label} donors={donors} />
            </>
          )}
        </>
      )}
    </Modal>
  );
}

function ResultTable({ rows, tone, label, donors }: { rows: any[]; tone: (a: string) => any; label: Record<string, string>; donors: any[] }) {
  return (
    <div className="import-table">
      <table className="table compact">
        <thead><tr><th>Row</th><th>Donor</th><th>Type</th><th>Email / city</th><th>Result</th></tr></thead>
        <tbody>{rows.slice(0, 500).map((r) => {
          const d = donors[r.row - 1] ?? {};
          return (
            <tr key={r.row}>
              <td className="muted">{r.row + 1}</td>
              <td>{r.name || <span className="muted">(no name)</span>}</td>
              <td className="small">{d.donor_type}</td>
              <td className="small">{[d.email, [d.city, d.state].filter(Boolean).join(', ')].filter(Boolean).join(' · ')}</td>
              <td><Badge tone={tone(r.action)}>{label[r.action]}</Badge>
                {r.match_name && r.action !== 'create' && <span className="muted small"> matches #{r.match_number} {r.match_name}</span>}
                {r.message && <span className="muted small"> {r.message}</span>}</td>
            </tr>
          );
        })}</tbody>
      </table>
      {rows.length > 500 && <p className="muted small">Showing the first 500 rows.</p>}
    </div>
  );
}
