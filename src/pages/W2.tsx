import React, { useState } from 'react';
import { useRpc } from '../lib/store';
import { date, download, money, toCsv } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Loading, Money, TAX_SHORT } from '../components/ui';
import { PayeeForm } from './Payees';

/** Totals per employee for the CPA or payroll service to prepare Forms W-2. */
export default function W2() {
  const [year, setYear] = useState<number>(new Date().getMonth() < 6 ? new Date().getFullYear() - 1 : new Date().getFullYear());
  const { data: r, error, loading, reload } = useRpc<any>('report_w2', { year });
  const [open, setOpen] = useState<string | null>(null);
  const [edit, setEdit] = useState<string | null>(null);
  if (loading && !r) return <Loading />;
  if (error) return <ErrorBox error={error} />;
  const emps: any[] = r.employees;
  const sum = (k: string) => emps.reduce((s, e) => s + Number(e[k]), 0);
  const csv = () => download(`bem-w2-worksheet-${r.year}.csv`, toCsv(emps.map((e) => ({ ...e, wages: Number(e.wages).toFixed(2), housing: Number(e.housing).toFixed(2),
    medical: Number(e.medical).toFixed(2), reimbursed: Number(e.reimbursed).toFixed(2), total_paid: Number(e.total_paid).toFixed(2) })),
    [['name', 'Employee'], ['tin_masked', 'SSN (masked)'], ['address', 'Address'], ['wages', 'Taxable wages (box 1)'], ['housing', 'Housing allowance (box 14)'],
     ['medical', 'Medical reimbursements'], ['reimbursed', 'Business expense reimbursements'], ['total_paid', 'Total paid']]), 'text/csv');
  return (
    <div className="report">
      <div className="toolbar no-print">
        <a href="#/reports">← Reports</a>
        <select value={year} onChange={(e) => setYear(Number(e.target.value))}>
          {Array.from({ length: 5 }, (_, i) => new Date().getFullYear() - i).map((y) => <option key={y} value={y}>{y}</option>)}
        </select>
        <div className="spacer" />
        <button className="btn" onClick={() => window.print()}>Print</button>
        <button className="btn primary" disabled={!emps.length} onClick={csv}>Download CSV</button>
      </div>
      <div className="report-head">
        <div className="org">{r.employer.name}</div>
        <h1>W-2 worksheet for {r.year}</h1>
        <div className="muted">What each employee was paid, split the way Form W-2 needs it. Give this to your payroll service or CPA; W-2s are due January 31, {r.year + 1}.</div>
      </div>
      <Card>
        {emps.length ? (
          <table className="table">
            <thead><tr><th>Employee</th><th>SSN</th><th className="num">Taxable wages<div className="muted small">box 1</div></th>
              <th className="num">Housing allowance<div className="muted small">box 14, excluded from box 1</div></th>
              <th className="num">Medical reimbursed</th><th className="num">Business expenses reimbursed<div className="muted small">not wages</div></th><th className="num">Total paid</th></tr></thead>
            <tbody>{emps.map((e) => (
              <React.Fragment key={e.payee_id}>
                <tr className="clickable" onClick={() => setOpen(open === e.payee_id ? null : e.payee_id)}>
                  <td style={{ minWidth: 190 }}>{e.name}<div className="muted small">{e.address || <span className="warn-text">address missing</span>}</div></td>
                  <td className="small">{e.has_ssn ? e.tin_masked : <span onClick={(ev) => { ev.stopPropagation(); setEdit(e.payee_id); }}><Badge tone="warn">add SSN</Badge></span>}</td>
                  <td className="num"><Money v={e.wages} /></td><td className="num"><Money v={e.housing} /></td>
                  <td className="num"><Money v={e.medical} /></td><td className="num"><Money v={e.reimbursed} /></td><td className="num"><Money v={e.total_paid} /></td>
                </tr>
                {open === e.payee_id && (
                  <tr><td colSpan={7}>
                    <table className="table compact">
                      <tbody>{e.detail.map((d: any, i: number) => (
                        <tr key={i}><td className="nowrap">{date(d.date)}</td><td className="small">{d.doc === 'bill' ? 'Expense report' : 'Payment'} #{d.number}</td>
                          <td>{d.account}</td><td className="small">{d.treatment ? TAX_SHORT[d.treatment] : ''}</td><td className="small muted">{d.memo}</td>
                          <td className="num"><Money v={d.amount} /></td></tr>
                      ))}</tbody>
                    </table>
                  </td></tr>
                )}
              </React.Fragment>
            ))}</tbody>
            <tfoot><tr className="total"><td colSpan={2}>Total</td><td className="num"><Money v={sum('wages')} /></td><td className="num"><Money v={sum('housing')} /></td>
              <td className="num"><Money v={sum('medical')} /></td><td className="num"><Money v={sum('reimbursed')} /></td><td className="num"><Money v={sum('total_paid')} /></td></tr></tfoot>
          </table>
        ) : <Empty>No payments to employees in {r.year}.</Empty>}
      </Card>
      <p className="muted small">
        Cash basis: amounts count in the year they were paid. Housing allowance must be designated by the board in advance; ministers may exclude it from income tax
        (within IRS limits) but it is subject to self-employment tax. Medical reimbursements are non-taxable only under a qualifying plan (QSEHRA or ICHRA); otherwise
        mark them taxable on the expense report. Business expense reimbursements under an accountable plan (receipts, within 60 days) are not wages.
        Ministers are usually exempt from FICA withholding; confirm withholding and box 2–6 amounts with your CPA.
      </p>
      {edit && <PayeeForm id={edit} onClose={() => setEdit(null)} onSaved={() => { setEdit(null); reload(); }} />}
    </div>
  );
}
