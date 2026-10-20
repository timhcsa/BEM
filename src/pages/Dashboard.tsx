import React from 'react';
import { go, useRpc } from '../lib/store';
import { date, money } from '../lib/format';
import { Avatar, Badge, Card, Empty, ErrorBox, Loading, Money, PageHeader } from '../components/ui';
import { MODE } from '../lib/api';

export default function Dashboard() {
  const { data: d, error, loading } = useRpc<any>('get_dashboard');
  const recurring = useRpc<any>('recurring_due', {});
  if (loading && !d) return <Loading />;
  if (error) return <ErrorBox error={error} />;
  const funds = d.funds as any[];
  const ministry = funds.filter((f) => f.kind !== 'missionary');
  const missionaries = funds.filter((f) => f.kind === 'missionary');
  const rec = d.last_reconciliation;
  const tie = Math.abs(Number(d.total_funds) - (Number(d.bank_balance) + Number(d.undeposited) - Number(d.unpaid_bills ?? 0))) < 0.005;

  return (
    <div>
      <PageHeader title="Dashboard" subtitle={`As of ${date(d.as_of)}`}
        actions={<>
          <a className="btn primary" href="#/gifts/new">+ Enter gifts</a>
          <a className="btn" href="#/bills">+ Enter a bill</a>
          <a className="btn" href="#/payments/new">+ Record a payment</a>
        </>} />

      {(() => {
        const open = (recurring.data?.items ?? []).filter((i: any) => !i.posted);
        if (!open.length) return null;
        const amt = open.reduce((s: number, i: any) => s + Number(i.total), 0);
        return (
          <div className="notice-bar">
            <span><strong>{open.length} recurring payment{open.length === 1 ? '' : 's'}</strong> due this month ({money(amt)}): {open.map((i: any) => i.payee_name).join(', ')}</span>
            <a className="btn small primary" href="#/recurring">Review & post</a>
          </div>
        );
      })()}
      {Number(d.unpaid_count) > 0 && (
        <div className="notice-bar">
          <span><strong>{d.unpaid_count} bill{d.unpaid_count === 1 ? '' : 's'} / expense report{d.unpaid_count === 1 ? '' : 's'}</strong> waiting to be paid ({money(d.unpaid_bills)})</span>
          <a className="btn small primary" href="#/bills">Review & pay</a>
        </div>
      )}
      {d.empty && (
        <Card className="welcome">
          <h2>Welcome to BEM Ledger</h2>
          <p>The ledger is empty. To get started:</p>
          <ol>
            <li>Enter your <a href="#/settings/opening">opening balances</a> for each fund (from QuickBooks, as of the day you switch over).</li>
            <li>Add your <a href="#/missionaries">missionaries</a> (each one gets a fund automatically) and <a href="#/donors">donors</a>.</li>
            <li>Start <a href="#/gifts/new">entering gifts</a>.</li>
          </ol>
          {MODE === 'local' && <p>Just exploring? <a href="#/settings/data">Load the sample data</a> to see the app with realistic numbers.</p>}
        </Card>
      )}

      <div className="tiles">
        <div className="tile">
          <span className="tile-label">Bank balance (books)</span>
          <Money v={d.bank_balance} className="big" />
          <span className="tile-note">
            {rec ? <>Reconciled to the {date(rec.statement_date)} statement</> : <>Not reconciled yet</>}
            {d.uncleared?.count ? <> · {d.uncleared.count} uncleared item{d.uncleared.count === 1 ? '' : 's'}</> : null}
          </span>
          <a className="tile-link" href="#/reconcile">Reconcile →</a>
        </div>
        <div className="tile">
          <span className="tile-label">Undeposited gifts</span>
          <Money v={d.undeposited} className="big" />
          <span className="tile-note">{d.undeposited_count} gift{d.undeposited_count === 1 ? '' : 's'} waiting for deposit</span>
          <a className="tile-link" href="#/deposits">Make a deposit →</a>
        </div>
        <div className="tile emphasis">
          <span className="tile-label">Total of all funds</span>
          <Money v={d.total_funds} className="big" />
          <span className="tile-note">
            {tie ? <Badge tone="good">✓ Balanced</Badge> : <Badge tone="bad">Out of balance</Badge>} = bank {money(d.bank_balance)} + undeposited {money(d.undeposited)}{Number(d.unpaid_bills) ? <> − unpaid bills {money(d.unpaid_bills)}</> : null}
          </span>
        </div>
        <div className="tile">
          <span className="tile-label">This month</span>
          <div className="tile-row"><span>Gifts ({d.month.gift_count})</span><Money v={d.month.gifts} /></div>
          <div className="tile-row"><span>Expenses &amp; bills</span><Money v={d.month.expenses} /></div>
          <div className="tile-row"><span>Admin fees to General</span><Money v={d.month.admin_fees} /></div>
        </div>
      </div>

      <div className="grid-2">
        <Card title="Ministry funds" actions={<a href="#/funds">All funds</a>}>
          <table className="table">
            <tbody>
              {ministry.map((f) => (
                <tr key={f.id} className="clickable" onClick={() => go(`funds/${f.id}`)}>
                  <td>{f.name} <span className="muted small">{f.restriction === 'with' ? 'restricted' : 'unrestricted'}</span></td>
                  <td className="num muted small">{Number(f.mtd_gifts) ? `+${money(f.mtd_gifts)} this month` : ''}</td>
                  <td className="num"><Money v={f.balance} accounting /></td>
                </tr>
              ))}
              <tr className="subtotal">
                <td>Missionary accounts ({missionaries.length})</td><td />
                <td className="num"><Money v={missionaries.reduce((s, f) => s + Number(f.balance), 0)} accounting /></td>
              </tr>
              <tr className="total">
                <td>Total of all funds</td><td />
                <td className="num"><Money v={d.total_funds} accounting /></td>
              </tr>
            </tbody>
          </table>
          <div className="net-assets">
            <div><span>Without donor restrictions</span><Money v={d.net_assets.without} accounting /></div>
            <div><span>With donor restrictions</span><Money v={d.net_assets.with} accounting /></div>
          </div>
        </Card>

        <Card title="Recent gifts" actions={<a href="#/gifts">All gifts</a>}>
          {d.recent_gifts.length ? (
            <table className="table compact">
              <tbody>
                {d.recent_gifts.map((g: any) => (
                  <tr key={g.id} className="clickable" onClick={() => go(`gifts?open=${g.id}`)}>
                    <td className="muted small nowrap">{date(g.gift_date)}</td>
                    <td>{g.donor_name}<div className="muted small">{g.funds}</div></td>
                    <td className="num"><Money v={g.total_amount} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <Empty>No gifts yet.</Empty>}
        </Card>
      </div>

      <Card title="Missionary accounts" actions={<a href="#/missionaries">Open missionaries</a>}>
        {missionaries.length ? (
          <div className="mini-missionaries">
            {missionaries.map((f) => (
              <button key={f.id} className="mini-m" onClick={() => go(`missionaries/${f.missionary_id}`)}>
                <Avatar name={f.name} url={f.photo_url} size={56} />
                <span className="mini-name">{f.name}</span>
                <Money v={f.balance} accounting className="mini-bal" />
                <span className="muted small">{Number(f.mtd_gifts) ? `${money(f.mtd_gifts)} in · ${money(f.mtd_fees)} fee` : 'No gifts this month'}</span>
              </button>
            ))}
          </div>
        ) : <Empty>No missionaries yet. <a href="#/missionaries">Add one</a>.</Empty>}
      </Card>
    </div>
  );
}
