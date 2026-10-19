import React, { useState } from 'react';
import { go, useRpc } from '../lib/store';
import { DONOR_TYPES, METHODS, date, download, money, toCsv } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Loading, Money, PageHeader, useDebounced } from '../components/ui';
import { DonorForm } from '../components/donors';
import DonorImport, { downloadDonorTemplate } from '../components/DonorImport';
import { DONOR_EXPORT_COLUMNS } from '../lib/csv';
import { rpc } from '../lib/api';

export default function Donors() {
  const [q, setQ] = useState('');
  const [inactive, setInactive] = useState(false);
  const dq = useDebounced(q);
  const { data, loading, error, reload } = useRpc<any[]>('search_donors', { q: dq, limit: 500, include_inactive: inactive });
  const [adding, setAdding] = useState(false);
  const [importing, setImporting] = useState(false);
  const rows = data ?? [];
  return (
    <div>
      <PageHeader title="Donors" subtitle="Individuals, households, churches and organizations who give to BEM."
        actions={<>
          <button className="btn" onClick={downloadDonorTemplate}>CSV template</button>
          <button className="btn" onClick={() => setImporting(true)}>Import CSV</button>
          <button className="btn" onClick={async () => {
            const all = await rpc<any[]>('search_donors', { limit: 100000, include_inactive: true });
            download(`bem-donors-${new Date().toISOString().slice(0, 10)}.csv`, toCsv(all.map((d) => ({ ...d, is_anonymous: d.is_anonymous ? 'yes' : '' })),
              [...DONOR_EXPORT_COLUMNS, ['ytd_total', 'Given this year'], ['last_gift_date', 'Last gift'], ['active', 'Active']]), 'text/csv');
          }}>Export CSV</button>
          <button className="btn primary" onClick={() => setAdding(true)}>+ New donor</button>
        </>} />
      <div className="filters no-print">
        <input type="search" autoFocus placeholder="Search by name, email, city, church or donor #" value={q} onChange={(e) => setQ(e.target.value)} style={{ minWidth: 340 }} />
        <label className="check inline"><input type="checkbox" checked={inactive} onChange={(e) => setInactive(e.target.checked)} /> Include inactive</label>
      </div>
      <ErrorBox error={error} />
      <Card>
        {loading && !data ? <Loading /> : rows.length ? (
          <table className="table">
            <thead><tr><th>#</th><th>Name</th><th>Type</th><th>Location</th><th>Email</th><th>Last gift</th><th className="num">This year</th></tr></thead>
            <tbody>{rows.map((d) => (
              <tr key={d.id} className={`clickable ${d.active ? '' : 'void'}`} onClick={() => go(`donors/${d.id}`)}>
                <td className="muted">{d.donor_number}</td>
                <td>{d.display_name} {d.is_anonymous && <Badge>anonymous</Badge>}</td>
                <td className="small">{DONOR_TYPES[d.donor_type]}</td>
                <td className="small">{[d.city, d.state].filter(Boolean).join(', ')}</td>
                <td className="small">{d.email}</td>
                <td className="small nowrap">{date(d.last_gift_date)}</td>
                <td className="num"><Money v={d.ytd_total} /></td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>{q ? 'No donors match.' : 'No donors yet.'}</Empty>}
      </Card>
      {adding && <DonorForm onCancel={() => setAdding(false)} onSaved={(d) => { setAdding(false); reload(); go(`donors/${d.id}`); }} />}
      {importing && <DonorImport onClose={() => setImporting(false)} onDone={reload} />}
    </div>
  );
}

export function DonorDetail({ id }: { id: string }) {
  const { data: d, error, reload } = useRpc<any>('get_donor', { id });
  const [editing, setEditing] = useState(false);
  if (error) return <ErrorBox error={error} />;
  if (!d) return <Loading />;
  const lastYear = new Date().getFullYear() - 1;
  return (
    <div>
      <div className="no-print back"><a href="#/donors">← All donors</a></div>
      <PageHeader title={<>{d.display_name} {!d.active && <Badge>inactive</Badge>}</>} subtitle={`Donor #${d.donor_number} · ${DONOR_TYPES[d.donor_type]}`}
        actions={<>
          <a className="btn" href={`#/reports/statements?donor=${d.id}&year=${lastYear}`}>{lastYear} giving statement</a>
          <a className="btn" href={`#/reports/statements?donor=${d.id}&year=${lastYear + 1}`}>{lastYear + 1} statement</a>
          <button className="btn" onClick={() => setEditing(true)}>Edit</button>
          <a className="btn primary" href="#/gifts/new">+ Enter a gift</a>
        </>} />
      <div className="grid-2">
        <Card title="Contact">
          <dl className="dl">
            {d.salutation && <><dt>Salutation</dt><dd>{d.salutation}</dd></>}
            {d.contact_name && <><dt>Contact</dt><dd>{d.contact_name}</dd></>}
            <dt>Address</dt><dd>{[d.address_line1, d.address_line2].filter(Boolean).join(', ')}<br />{[d.city, d.state, d.postal_code].filter(Boolean).join(' ')}</dd>
            <dt>Email</dt><dd>{d.email ? <a href={`mailto:${d.email}`}>{d.email}</a> : '—'}</dd>
            <dt>Phone</dt><dd>{d.phone ?? '—'}</dd>
            {d.church_affiliation && <><dt>Home church</dt><dd>{d.church_affiliation}</dd></>}
            <dt>Receipts</dt><dd>{d.receipt_preference === 'none' ? "Don't send" : `By ${d.receipt_preference}`}</dd>
            {d.notes && <><dt>Notes</dt><dd>{d.notes}</dd></>}
          </dl>
        </Card>
        <Card title="Giving by year">
          <table className="table compact">
            <tbody>
              {d.by_year.map((y: any) => <tr key={y.year}><td>{y.year}</td><td className="muted">{y.count} gifts</td><td className="num"><Money v={y.total} /></td></tr>)}
              <tr className="total"><td>Lifetime</td><td /><td className="num"><Money v={d.lifetime_total} /></td></tr>
            </tbody>
          </table>
        </Card>
      </div>
      <Card title="Gifts">
        {d.gifts.length ? (
          <table className="table">
            <thead><tr><th>#</th><th>Date</th><th>Designation</th><th>Received as</th><th className="num">Amount</th></tr></thead>
            <tbody>{d.gifts.map((g: any) => (
              <tr key={g.id} className={`clickable ${g.status === 'void' ? 'void' : ''}`} onClick={() => go(`gifts?open=${g.id}`)}>
                <td className="muted">{g.gift_number}</td><td className="nowrap">{date(g.gift_date)}</td><td>{g.funds}</td>
                <td className="small">{METHODS[g.method]} {g.reference}</td><td className="num"><Money v={g.total_amount} /> {g.status === 'void' && <Badge tone="bad">void</Badge>}</td>
              </tr>
            ))}</tbody>
          </table>
        ) : <Empty>No gifts recorded yet.</Empty>}
      </Card>
      {editing && <DonorForm initial={d} onCancel={() => setEditing(false)} onSaved={() => { setEditing(false); reload(); }} />}
    </div>
  );
}
