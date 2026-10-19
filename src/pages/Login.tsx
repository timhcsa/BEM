import React, { useState } from 'react';
import { supabase } from '../lib/api';

export default function Login() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <div className="login">
      <form className="login-card" onSubmit={async (e) => {
        e.preventDefault(); setBusy(true); setErr(null);
        const { error } = await supabase!.auth.signInWithPassword({ email, password });
        if (error) setErr(error.message);
        setBusy(false);
      }}>
        <img className="login-logo" src="/bem-logo.jpg" alt="Barnabas Enrichment Ministries" />
        <h1>Ledger</h1>
        <p className="muted">Barnabas Enrichment Ministries · administrators only</p>
        <label className="field"><span className="label">Email</span><input type="email" autoFocus value={email} onChange={(e) => setEmail(e.target.value)} /></label>
        <label className="field"><span className="label">Password</span><input type="password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
        {err && <div className="error-box">{err}</div>}
        {msg && <div className="ok-box">{msg}</div>}
        <button className="btn primary block" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        <button type="button" className="linklike small" onClick={async () => {
          if (!email) { setErr('Enter your email first'); return; }
          const { error } = await supabase!.auth.resetPasswordForEmail(email, { redirectTo: window.location.origin });
          if (error) setErr(error.message); else setMsg('Check your email for a reset link.');
        }}>Forgot password?</button>
      </form>
    </div>
  );
}
