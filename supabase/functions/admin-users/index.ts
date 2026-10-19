// =====================================================================
// BEM Ledger — admin-users Edge Function (Supabase, Deno)
// Lets an administrator manage logins from inside the app:
//   list · create (with a temporary password) · set_password · remove
// Uses the project's service role key, which Supabase provides to Edge
// Functions automatically and which never reaches the browser.
// Every request must come from a signed-in user listed in app_admins.
//
// Deploy: Supabase dashboard > Edge Functions > Deploy a new function >
//         Via Editor > name it "admin-users" > paste this file > Deploy.
// =====================================================================
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// The privileged key Supabase gives every Edge Function: the legacy service_role
// key, or (newer projects) the default secret key.
function serviceKey(): string {
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) return legacy;
  const raw = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (raw) {
    try { const keys = JSON.parse(raw); return keys.default ?? Object.values(keys)[0] as string; } catch { return raw; }
  }
  throw new Error('No service key available to the function');
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'Use POST' }, 405);

  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Who is calling, and are they an administrator?
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    if (whoErr || !who?.user) return json({ error: 'Please sign in again.' }, 401);
    const me = who.user;
    const { data: meAdmin } = await admin.from('app_admins').select('user_id').eq('user_id', me.id).maybeSingle();
    if (!meAdmin) return json({ error: 'Only administrators can manage users.' }, 403);

    const body = await req.json().catch(() => ({}));
    const log = (action: string, objectId: string | null, detail: Record<string, unknown>) =>
      admin.from('audit_log').insert({ actor: me.email ?? me.id, action, object: 'user', object_id: objectId, detail });

    switch (body.action) {
      case 'list': {
        const { data, error } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
        if (error) throw error;
        const { data: admins } = await admin.from('app_admins').select('user_id');
        const isAdmin = new Set((admins ?? []).map((a: { user_id: string }) => a.user_id));
        return json({
          me: me.id,
          users: data.users
            .map((u) => ({
              id: u.id, email: u.email, name: (u.user_metadata as any)?.name ?? null,
              created_at: u.created_at, last_sign_in_at: u.last_sign_in_at ?? null, is_admin: isAdmin.has(u.id),
            }))
            .sort((a, b) => String(a.email).localeCompare(String(b.email))),
        });
      }

      case 'create': {
        const email = String(body.email ?? '').trim().toLowerCase();
        const password = String(body.password ?? '');
        const name = String(body.name ?? '').trim() || null;
        if (!EMAIL.test(email)) return json({ error: 'Enter a valid email address.' }, 400);
        if (password.length < 10) return json({ error: 'The temporary password must be at least 10 characters.' }, 400);
        const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { name } });
        if (error) {
          if (/already|registered|exists/i.test(error.message)) return json({ error: 'A user with that email already exists.' }, 400);
          throw error;
        }
        const { error: insErr } = await admin.from('app_admins').insert({ user_id: data.user!.id, email });
        if (insErr) throw insErr;
        await log('create', data.user!.id, { email, name });
        return json({ ok: true, id: data.user!.id });
      }

      case 'set_password': {
        const id = String(body.user_id ?? '');
        const password = String(body.password ?? '');
        if (password.length < 10) return json({ error: 'The password must be at least 10 characters.' }, 400);
        const { error } = await admin.auth.admin.updateUserById(id, { password });
        if (error) throw error;
        await log('set_password', id, {});
        return json({ ok: true });
      }

      case 'remove': {
        const id = String(body.user_id ?? '');
        if (id === me.id) return json({ error: "You can't remove your own login." }, 400);
        const { count } = await admin.from('app_admins').select('user_id', { count: 'exact', head: true });
        const { data: target } = await admin.from('app_admins').select('email').eq('user_id', id).maybeSingle();
        if (target && (count ?? 0) <= 1) return json({ error: 'There must always be at least one administrator.' }, 400);
        await admin.from('app_admins').delete().eq('user_id', id);
        const { error } = await admin.auth.admin.deleteUser(id);
        if (error) throw error;
        await log('remove', id, { email: target?.email ?? null });
        return json({ ok: true });
      }

      default:
        return json({ error: 'Unknown action' }, 400);
    }
  } catch (e) {
    return json({ error: (e as Error)?.message ?? String(e) }, 400);
  }
});
