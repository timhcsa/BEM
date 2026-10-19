import React, { useState } from 'react';
import { useRpc } from '../lib/store';
import { date, download, money, toCsv, today } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Loading, Money, TAX_SHORT } from '../components/ui';
import { PayeeForm } from './Payees';

const DUE = (y: number) => `January 31, ${y + 1}`;

function RecipientCopy({ r, payer, year, form }: { r: any; payer: any; year: number; form: 'NEC' | 'MISC' }) {
  const addr2 = [r.city, r.state].filter(Boolean).join(', ') + (r.postal_code ? ` ${r.postal_code}` : '');
  return (
    <article className="form-1099">
      <div className="f-top">
        <div className="f-payer">
          <div className="f-label">PAYER'S name, street address, city or town, state or province, country, ZIP or foreign postal code, and telephone no.</div>
          <div>{payer.name}</div><div>{payer.address}</div><div>{payer.phone}</div>
        </div>
        <div className="f-title">
          <div className="f-year">{year}</div>
          <div className="f-name">Form 1099-{form}</div>
          <div>{form === 'NEC' ? 'Nonemployee Compensation' : 'Miscellaneous Information'}</div>
          <div className="f-copy">Copy B<br />For Recipient</div>
        </div>
      </div>
      <div className="f-grid">
        <div><div className="f-label">PAYER'S TIN</div>{payer.ein || <span className="f-missing">EIN missing</span>}</div>
        <div><div className="f-label">RECIPIENT'S TIN</div>{r.tin_masked || <span className="f-missing">missing</span>}</div>
        {form === 'NEC'
          ? <div className="f-box"><div className="f-label">1 Nonemployee compensation</div><strong>{money(r.nec1)}</strong></div>
          : <>
              <div className="f-box"><div className="f-label">1 Rents</div><strong>{Number(r.misc1) ? money(r.misc1) : ''}</strong></div>
              <div className="f-box"><div className="f-label">3 Other income</div><strong>{Number(r.misc3) ? money(r.misc3) : ''}</strong></div>
            </>}
        <div className="f-wide"><div className="f-label">RECIPIENT'S name</div>{r.legal_name}{r.business_name ? <div>{r.business_name}</div> : null}</div>
        <div className="f-box"><div className="f-label">4 Federal income tax withheld</div>{money(0)}</div>
        <div className="f-full"><div className="f-label">Street address (including apt. no.)</div>{r.address_line1} {r.address_line2}</div>
        <div className="f-full"><div className="f-label">City or town, state or province, country, and ZIP or foreign postal code</div>{addr2}</div>
      </div>
      <p className="f-legend">This is important tax information and is being furnished to the IRS. If you are required to file a return, a negligence penalty or other sanction may be imposed on you if this income is taxable and the IRS determines that it has not been reported.</p>
      {form === 'NEC' && Number(r.housing) > 0 && (
        <p className="f-note">Note: In {year}, {money(r.housing)} was also paid to you as a board-designated minister's housing allowance. It is not included in box 1. It may be excluded from income tax (up to the limits that apply) but is subject to self-employment tax; keep this for your records.</p>
      )}
      <div className="f-foot">Form 1099-{form} (keep for your records) · Substitute statement furnished by {payer.name} · Recipient copy, not filed with the IRS</div>
    </article>
  );
}

export default function Form1099() {
  const [year, setYear] = useState<number>(new Date().getMonth() < 6 ? new Date().getFullYear() - 1 : new Date().getFullYear());
  const { data: r, error, loading, reload } = useRpc<any>('report_1099', { year });
  const [edit, setEdit] = useState<string | null>(null);
  const [open, setOpen] = useState<string | null>(null);
  const [printing, setPrinting] = useState<'NEC' | 'MISC' | null>(null);
  if (loading && !r) return <Loading />;
  if (error) return <ErrorBox error={error} />;
  const recips: any[] = r.recipients;
  const nec = recips.filter((x) => x.needs_nec && x.is_1099);
  const misc = recips.filter((x) => x.needs_misc && x.is_1099);
  const problems = [...nec, ...misc].filter((x) => x.problems.some((p: string) => !p.startsWith('Legal name')));
  const notMarked = recips.filter((x) => !x.is_1099 && (x.needs_nec || x.needs_misc));

  const efileCsv = () => {
    const rows = [...nec.map((x) => ({ ...x, form: '1099-NEC' })), ...misc.map((x) => ({ ...x, form: '1099-MISC' }))].map((x) => ({
      form: x.form, year: r.year, payer_name: r.payer.name, payer_tin: r.payer.ein, payer_address: r.payer.address, payer_phone: r.payer.phone,
      recipient_tin_type: x.tin_type === 'ein' ? 'EIN' : 'SSN', recipient_tin: x.tin, recipient_name: x.legal_name, recipient_name2: x.business_name,
      address1: x.address_line1, address2: x.address_line2, city: x.city, state: x.state, zip: x.postal_code, email: x.email,
      nec_box1: x.form === '1099-NEC' ? Number(x.nec1).toFixed(2) : '', misc_box1_rents: x.form === '1099-MISC' && Number(x.misc1) ? Number(x.misc1).toFixed(2) : '',
      misc_box3_other: x.form === '1099-MISC' && Number(x.misc3) ? Number(x.misc3).toFixed(2) : '', fed_withheld: '0.00',
    }));
    download(`bem-1099-efile-${r.year}.csv`, toCsv(rows, Object.keys(rows[0] ?? { form: '' }).map((k) => [k, k] as [string, string])), 'text/csv');
  };

  if (printing) {
    const list = printing === 'NEC' ? nec : misc;
    return (
      <div className="report">
        <div className="toolbar no-print">
          <button className="linklike" onClick={() => setPrinting(null)}>← Back to 1099 summary</button>
          <span className="muted small">{list.length} recipient copies · each prints on its own page</span>
          <div className="spacer" />
          <button className="btn primary" onClick={() => window.print()}>Print / save as PDF</button>
        </div>
        {list.map((x) => <RecipientCopy key={x.payee_id} r={x} payer={r.payer} year={r.year} form={printing} />)}
      </div>
    );
  }

  return (
    <div className="report">
      <div className="toolbar no-print">
        <a href="#/reports">← Reports</a>
        <select value={year} onChange={(e) => setYear(Number(e.target.value))}>
          {Array.from({ length: 5 }, (_, i) => new Date().getFullYear() - i).map((y) => <option key={y} value={y}>{y}</option>)}
        </select>
        <div className="spacer" />
        <a className="btn" href="#/payees">Payees & W-9s</a>
        <button className="btn" disabled={!nec.length} onClick={() => setPrinting('NEC')}>Print 1099-NEC recipient copies</button>
        {misc.length > 0 && <button className="btn" onClick={() => setPrinting('MISC')}>Print 1099-MISC copies</button>}
        <button className="btn primary" disabled={!nec.length && !misc.length} onClick={efileCsv}>Download e-file CSV</button>
      </div>
      <div className="report-head">
        <div className="org">{r.payer.name}</div>
        <h1>Forms 1099 for {r.year}</h1>
        <div className="muted">Recipient copies and IRS filing due {DUE(r.year)} · 1099-NEC threshold for {r.year}: {money(r.threshold)}</div>
      </div>

      {!r.payer.ein || r.payer.ein === '00-0000000' ? <ErrorBox error="BEM's EIN is missing. Add it under Settings → Organization before printing 1099s." /> : null}
      {problems.length > 0 && (
        <div className="warn-box">
          <strong>{problems.length} recipient{problems.length === 1 ? ' needs' : 's need'} information before filing:</strong>
          <ul>{problems.map((x) => <li key={x.payee_id}><button className="linklike" onClick={() => setEdit(x.payee_id)}>{x.display_name}</button>: {x.problems.filter((p: string) => !p.startsWith('Legal name')).join('; ')}</li>)}</ul>
        </div>
      )}
      {notMarked.length > 0 && (
        <div className="warn-box">
          <strong>Paid over the threshold but not marked to receive a 1099:</strong> {notMarked.map((x, i) => <React.Fragment key={x.payee_id}>{i ? ', ' : ''}<button className="linklike" onClick={() => setEdit(x.payee_id)}>{x.display_name}</button></React.Fragment>)}.
          {' '}Corporations usually don't need one; individuals and LLCs usually do (attorneys always do).
        </div>
      )}

      <Card>
        {recips.length ? (
          <table className="table">
            <thead><tr><th>Recipient</th><th>Taxpayer ID</th><th className="num">1099-NEC box 1</th><th className="num">MISC rents / other</th>
              <th className="num">Housing allowance</th><th className="num">Reimbursed (not reported)</th><th>Status</th></tr></thead>
            <tbody>{recips.map((x) => (<React.Fragment key={x.payee_id}>
              <tr className="clickable" onClick={() => setEdit(x.payee_id)}>
                <td>{x.legal_name}{x.legal_name !== x.display_name && <div className="muted small">{x.display_name}</div>}</td>
                <td className="small">{x.tin_masked ?? <Badge tone="warn">missing</Badge>}</td>
                <td className="num"><Money v={x.nec1} /></td>
                <td className="num">{Number(x.misc1) + Number(x.misc3) ? money(Number(x.misc1) + Number(x.misc3)) : '—'}</td>
                <td className="num muted">{Number(x.housing) ? money(x.housing) : '—'}</td>
                <td className="num muted">{Number(x.reimbursed) ? money(x.reimbursed) : '—'}</td>
                <td>{!x.is_1099 ? <Badge>not marked</Badge>
                  : x.needs_nec || x.needs_misc ? (x.problems.some((p: string) => !p.startsWith('Legal name')) ? <Badge tone="warn">needs info</Badge> : <Badge tone="good">ready</Badge>)
                  : <Badge>below {money(r.threshold)}</Badge>}
                  {' '}<button className="linklike small" onClick={(e) => { e.stopPropagation(); setOpen(open === x.payee_id ? null : x.payee_id); }}>{open === x.payee_id ? 'hide' : 'details'}</button></td>
              </tr>
              {open === x.payee_id && (
                <tr className="detail-row"><td colSpan={7}>
                  <table className="table compact">
                    <thead><tr><th>Date</th><th>Payment #</th><th>Category</th><th>Treatment</th><th>Counted as</th><th className="num">Amount</th></tr></thead>
                    <tbody>{(x.detail ?? []).map((l: any, i: number) => (
                      <tr key={i}><td>{date(l.date)}</td><td>{l.disb_number}</td><td>{l.account}{l.memo ? ` (${l.memo})` : ''}</td>
                        <td>{l.treatment ? TAX_SHORT[l.treatment] : <span className="muted">account default</span>}</td>
                        <td>{({ nec1: <Badge tone="warn">1099-NEC box 1</Badge>, misc1: <Badge tone="warn">1099-MISC rents</Badge>, misc3: <Badge tone="warn">1099-MISC other</Badge>,
                               housing: <Badge>housing allowance</Badge>, reimbursement: <Badge>not reported (reimbursement)</Badge>, card: <Badge>card (1099-K)</Badge> } as any)[l.counted] ?? <Badge>not reported</Badge>}</td>
                        <td className="num">{money(l.amount)}</td></tr>
                    ))}</tbody>
                  </table>
                  <p className="muted small">To change how a payment is treated, void it on the Payments page and re-enter it with the right tax choice.</p>
                </td></tr>
              )}
            </React.Fragment>))}</tbody>
          </table>
        ) : <Empty>No payments to 1099 payees in {r.year}.</Empty>}
      </Card>

      <Card title="How to file">
        <ol className="steps">
          <li><strong>Check each payment's tax choice.</strong> Payments to missionaries are marked taxable (salary, extra funds for personal use: box 1), non-taxable (business-expense reimbursements with receipts: not reported) or housing allowance. Click “details” on any row to see exactly what was counted.</li>
          <li><strong>Collect W-9s.</strong> Click any name above to enter the legal name, SSN/EIN and address from their Form W-9.</li>
          <li><strong>Give each person their copy by {DUE(r.year)}.</strong> Print the recipient copies (Copy B), or save them as PDF and email them if the recipient has agreed to receive it electronically.</li>
          <li><strong>File with the IRS by {DUE(r.year)}.</strong> Easiest: the IRS's free <em>Information Returns Intake System (IRIS)</em> portal. Enter the forms there, or use the e-file CSV with IRIS or a filing service such as Track1099 or Tax1099. Paper filing needs the official red-ink Copy A and Form 1096; Copy A can't be printed on plain paper.</li>
          <li><strong>Indiana:</strong> check whether you also have to file the 1099s with the state (through the Combined Federal/State program or INTIME).</li>
        </ol>
        <p className="muted small">What's counted: payments in {r.year} charged to accounts marked for a 1099 box (Settings → Chart of accounts). Card payments are left out because the card company reports them on Form 1099-K. The minister's housing allowance and accountable-plan reimbursements are shown for reference only. <strong>If BEM's missionaries are employees, they need a W-2 from payroll instead of a 1099. Confirm how they're classified with BEM's CPA.</strong></p>
      </Card>
      {edit && <PayeeForm id={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
      <div className="print-only muted small">Printed {date(today())}</div>
    </div>
  );
}
