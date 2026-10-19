import React, { useEffect, useState } from 'react';
import { MODE, rpc, supabase } from './lib/api';
import { AppProvider, useApp, useRoute } from './lib/store';
import Dashboard from './pages/Dashboard';
import Gifts from './pages/Gifts';
import Deposits from './pages/Deposits';
import Payments from './pages/Payments';
import Missionaries, { FundAccount } from './pages/Missionaries';
import Funds from './pages/Funds';
import Donors, { DonorDetail } from './pages/Donors';
import Reconcile from './pages/Reconcile';
import Reports from './pages/Reports';
import Adjustments from './pages/Adjustments';
import Settings from './pages/Settings';
import Payees from './pages/Payees';
import Recurring from './pages/Recurring';
import Login from './pages/Login';

const NAV: [string, string, string][] = [
  ['dashboard', 'Dashboard', '◧'],
  ['gifts/new', 'Enter gifts', '＋'],
  ['gifts', 'Gifts', '♥'],
  ['deposits', 'Deposits', '⇩'],
  ['payments', 'Payments', '⇧'],
  ['recurring', 'Recurring payments', '↻'],
  ['payees', 'Payees & W-9s', '✎'],
  ['missionaries', 'Missionaries', '☺'],
  ['donors', 'Donors', '☰'],
  ['funds', 'Funds', '▤'],
  ['reconcile', 'Reconcile bank', '✓'],
  ['adjustments', 'Transfers & adjustments', '⇄'],
  ['reports', 'Reports', '▦'],
  ['settings', 'Settings', '⚙'],
];

function Shell({ onSignOut, email }: { onSignOut?: () => void; email?: string }) {
  const route = useRoute();
  const { lookups } = useApp();
  const [menuOpen, setMenuOpen] = useState(false);
  const [page, a, b] = route;
  useEffect(() => setMenuOpen(false), [route.join('/')]);

  let content: React.ReactNode;
  switch (page) {
    case 'gifts': content = <Gifts sub={a} />; break;
    case 'deposits': content = <Deposits />; break;
    case 'payments': content = <Payments />; break;
    case 'payees': content = <Payees />; break;
    case 'recurring': content = <Recurring />; break;
    case 'missionaries': content = a ? <FundAccount key={a} missionaryId={a} /> : <Missionaries />; break;
    case 'funds': content = a ? <FundAccount key={a} fundId={a} /> : <Funds />; break;
    case 'donors': content = a ? <DonorDetail key={a} id={a} /> : <Donors />; break;
    case 'reconcile': content = <Reconcile />; break;
    case 'adjustments': content = <Adjustments />; break;
    case 'reports': content = <Reports sub={a} />; break;
    case 'settings': content = <Settings sub={a} />; break;
    default: content = <Dashboard />;
  }
  const current = route.join('/');
  const active = (k: string) => (k === current || (k !== 'gifts/new' && k === page && !(page === 'gifts' && a === 'new')) ? 'active' : '');
  const s = lookups?.settings;

  return (
    <div className="app">
      <aside className={`sidebar no-print ${menuOpen ? 'open' : ''}`}>
        <a className="brand" href="#/dashboard">
          <span className="brand-logo"><img src={s?.logo_url || '/bem-logo.jpg'} alt={s?.org_name ?? 'Barnabas Enrichment Ministries'} /></span>
          <span className="brand-sub"><strong>Ledger</strong><small>Finance · Admin</small></span>
        </a>
        <nav>
          {NAV.map(([k, label, icon]) => (
            <a key={k} href={`#/${k}`} className={active(k)}><span className="nav-icon" aria-hidden>{icon}</span>{label}</a>
          ))}
        </nav>
        <div className="sidebar-foot">
          {MODE === 'local'
            ? <span className="mode local" title="Data is stored in this browser only. Use Settings > Data & backup to download a copy.">Local test database</span>
            : <span className="mode live">Live · {email}</span>}
          {s?.closed_through && <span className="muted small">Books closed through {s.closed_through}</span>}
          {onSignOut && <button className="linklike small" onClick={onSignOut}>Sign out</button>}
        </div>
      </aside>
      <button className="menu-btn no-print" onClick={() => setMenuOpen(!menuOpen)} aria-label="Menu">☰</button>
      <main className="main">{lookups ? content : <div className="loading">Opening the ledger…</div>}</main>
    </div>
  );
}

export default function App() {
  const [state, setState] = useState<'checking' | 'signed_out' | 'not_admin' | 'ready'>(MODE === 'local' ? 'ready' : 'checking');
  const [email, setEmail] = useState<string>('');

  useEffect(() => {
    if (MODE !== 'supabase') return;
    const check = async () => {
      const { data } = await supabase!.auth.getSession();
      if (!data.session) { setState('signed_out'); return; }
      try {
        const me = await rpc<{ email: string; is_admin: boolean }>('whoami');
        setEmail(me.email); setState(me.is_admin ? 'ready' : 'not_admin');
      } catch { setState('not_admin'); }
    };
    check();
    const { data: sub } = supabase!.auth.onAuthStateChange(async (event) => {
      if (event === 'PASSWORD_RECOVERY') {
        const pw = window.prompt('Choose a new password (at least 8 characters):');
        if (pw && pw.length >= 8) {
          const { error } = await supabase!.auth.updateUser({ password: pw });
          window.alert(error ? error.message : 'Password updated.');
        }
      }
      check();
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  if (state === 'checking') return <div className="loading">Loading…</div>;
  if (state === 'signed_out') return <Login />;
  if (state === 'not_admin') {
    return (
      <div className="login"><div className="login-card">
        <h1>No access yet</h1>
        <p>You're signed in as {email || 'this user'}, but this account isn't an administrator of BEM Ledger. Ask an administrator to add you.</p>
        <button className="btn" onClick={() => supabase!.auth.signOut()}>Sign out</button>
      </div></div>
    );
  }
  return (
    <AppProvider>
      <Shell email={email} onSignOut={MODE === 'supabase' ? () => supabase!.auth.signOut() : undefined} />
    </AppProvider>
  );
}
