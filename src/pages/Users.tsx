import React, { useCallback, useEffect, useState } from 'react';
import { MODE, adminUsers, changeMyPassword } from '../lib/api';
import { useApp } from '../lib/store';
import { date } from '../lib/format';
import { Badge, Card, Empty, ErrorBox, Field, Loading, Modal } from '../components/ui';

/** A readable random password: 3 words-ish chunks + digits, 14+ characters. */
function makePassword(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';
  const a = new Uint32Array(14);
  crypto.getRandomValues(a);
  const s = Array.from(a, (n) => chars[n % chars.length]).join('');
  return `${s.slice(0, 5)}-${s.slice(5, 10)}-${s.slice(10, 14)}`;
}

function PasswordField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="pw-row">
      <input value={value} onChange={(e) => onChange(e.target.value)} autoComplete="new-password" spellCheck={false} />
      <button type="button" className="btn small" onClick={() => onChange(makePassword())}>Generate</button>
      {value && <button type="button" className="btn small" onClick={() => navigator.clipboard?.writeText(value)}>Copy</button>}
    </div>
  );
}

function MyPassword() {
  const { toast } = useApp();
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [err, setErr] = useState<string | null>(null);
  return (
    <Card title="Your password">
      <div className="form-grid">
        <Field label="New password" hint="At least 10 characters"><input type="password" value={pw} onChange={(e) => setPw(e.target.value)} autoComplete="new-password" /></Field>
        <Field label="Type it again"><input type="password" value={pw2} onChange={(e) => setPw2(e.target.value)} autoComplete="new-password" /></Field>
      </div>
      <ErrorBox error={err} />
      <div className="form-actions">
        <button className="btn primary" disabled={!pw} onClick={async () => {
          setErr(null);
          if (pw.length < 10) { setErr('Use at least 10 characters.'); return; }
          if (pw !== pw2) { setErr("The two passwords don't match."); return; }
          try { await changeMyPassword(pw); setPw(''); setPw2(''); toast('Your password was changed'); } catch (e: any) { setErr(e.message); }
        }}>Change my password</button>
      </div>
    </Card>
  );
}

export default function Users() {
  const { toast } = useApp();
  const [data, setData] = useState<{ me: string; users: any[] } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [resetFor, setResetFor] = useState<any | null>(null);
  const [created, setCreated] = useState<{ email: string; password: string } | null>(null);

  const load = useCallback(async () => {
    setErr(null);
    try { setData(await adminUsers('list')); } catch (e: any) { setErr(e.message); }
  }, []);
  useEffect(() => { if (MODE === 'supabase') load(); }, [load]);

  if (MODE !== 'supabase') {
    return <Card title="Users"><Empty>User logins are managed on the live site. This local test copy has no logins.</Empty></Card>;
  }

  return (
    <>
      <Card title="Users" actions={<button className="btn primary small" onClick={() => setAdding(true)}>+ Add user</button>}>
        <p className="muted small">Everyone listed here can sign in and has full administrator access to BEM's books. Remove people who no longer need access.</p>
        <ErrorBox error={err} />
        {!data && !err ? <Loading /> : data && (
          <table className="table">
            <thead><tr><th>Name</th><th>Email</th><th>Access</th><th>Last signed in</th><th>Added</th><th /></tr></thead>
            <tbody>{data.users.map((u) => (
              <tr key={u.id}>
                <td>{u.name ?? <span className="muted">—</span>} {u.id === data.me && <Badge tone="info">you</Badge>}</td>
                <td>{u.email}</td>
                <td>{u.is_admin ? <Badge tone="good">Administrator</Badge> : <Badge tone="warn">No access</Badge>}</td>
                <td className="small">{u.last_sign_in_at ? new Date(u.last_sign_in_at).toLocaleString() : <span className="muted">never</span>}</td>
                <td className="small">{date(String(u.created_at).slice(0, 10))}</td>
                <td className="nowrap">
                  {u.id !== data.me && <>
                    <button className="btn small" onClick={() => setResetFor(u)}>Set password</button>{' '}
                    <button className="btn small danger-outline" onClick={async () => {
                      if (!confirm(`Remove ${u.email}? They will no longer be able to sign in. Their past entries stay in the books.`)) return;
                      try { await adminUsers('remove', { user_id: u.id }); toast(`${u.email} removed`); load(); } catch (e: any) { toast(e.message, 'error'); }
                    }}>Remove</button>
                  </>}
                </td>
              </tr>
            ))}</tbody>
          </table>
        )}
      </Card>
      <MyPassword />
      {adding && <AddUser onClose={() => setAdding(false)} onCreated={(c) => { setAdding(false); setCreated(c); load(); }} />}
      {resetFor && <ResetPassword user={resetFor} onClose={() => setResetFor(null)} onDone={(c) => { setResetFor(null); setCreated(c); }} />}
      {created && (
        <Modal title="Share these sign-in details" size="sm" onClose={() => setCreated(null)}
          footer={<button className="btn primary" onClick={() => setCreated(null)}>Done</button>}>
          <p>Give this person their sign-in details privately (in person or by phone is best). They should change the password under <strong>Settings → Users</strong> after signing in.</p>
          <dl className="dl">
            <dt>Website</dt><dd>{window.location.origin}</dd>
            <dt>Email</dt><dd>{created.email}</dd>
            <dt>Password</dt><dd><code className="pw">{created.password}</code></dd>
          </dl>
          <button className="btn small" onClick={() => navigator.clipboard?.writeText(`BEM Ledger\n${window.location.origin}\nEmail: ${created.email}\nTemporary password: ${created.password}`)}>Copy all</button>
          <p className="muted small">This password is shown only once.</p>
        </Modal>
      )}
    </>
  );
}

function AddUser({ onClose, onCreated }: { onClose: () => void; onCreated: (c: { email: string; password: string }) => void }) {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState(makePassword());
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <Modal title="Add a user" onClose={onClose}
      footer={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" disabled={busy} onClick={async () => {
        setBusy(true); setErr(null);
        try { await adminUsers('create', { name, email, password }); onCreated({ email: email.trim().toLowerCase(), password }); }
        catch (e: any) { setErr(e.message); } finally { setBusy(false); }
      }}>{busy ? 'Adding…' : 'Add user'}</button></>}>
      <div className="form-grid">
        <Field label="Name"><input autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. Sandy Hewitt" /></Field>
        <Field label="Email (their sign-in)"><input type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></Field>
        <Field label="Temporary password" wide hint="A strong one is filled in for you. You'll see it again on the next screen to share."><PasswordField value={password} onChange={setPassword} /></Field>
      </div>
      <p className="muted small">New users get full administrator access to BEM Ledger.</p>
      <ErrorBox error={err} />
    </Modal>
  );
}

function ResetPassword({ user, onClose, onDone }: { user: any; onClose: () => void; onDone: (c: { email: string; password: string }) => void }) {
  const [password, setPassword] = useState(makePassword());
  const [err, setErr] = useState<string | null>(null);
  return (
    <Modal title={`New password for ${user.email}`} size="sm" onClose={onClose}
      footer={<><button className="btn" onClick={onClose}>Cancel</button><button className="btn primary" onClick={async () => {
        setErr(null);
        try { await adminUsers('set_password', { user_id: user.id, password }); onDone({ email: user.email, password }); } catch (e: any) { setErr(e.message); }
      }}>Set password</button></>}>
      <p>Use this when someone forgets their password. Their old password stops working right away.</p>
      <Field label="New temporary password"><PasswordField value={password} onChange={setPassword} /></Field>
      <ErrorBox error={err} />
    </Modal>
  );
}
