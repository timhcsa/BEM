-- =====================================================================
-- BEM Ledger — Supabase-only security layer.
-- NOT run by the local (in-browser) database; run it on Supabase after
-- the other migration files.
--
--   * Only users listed in app_admins can read or change anything.
--   * Row-level security on every table; anonymous visitors get nothing.
--   * current_actor() records the signed-in user's email on every posting.
-- =====================================================================

create table if not exists app_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where user_id = auth.uid())
$$;

create or replace function current_actor() returns text
language sql stable as $$
  select coalesce(auth.jwt() ->> 'email', auth.uid()::text, 'system')
$$;

-- Row-level security: admins only, on every table in public.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' and tablename <> 'app_admins' loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

alter table app_admins enable row level security;
drop policy if exists admins_read_self on app_admins;
create policy admins_read_self on app_admins for select to authenticated using (user_id = auth.uid());

-- Block anonymous access to the API functions. (RLS already hides the
-- data; this keeps the functions themselves private as well.)
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from anon, public', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

-- Who am I? Used by the app after sign-in.
create or replace function whoami(p jsonb) returns jsonb
language sql stable as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email', 'is_admin', is_admin())
$$;
revoke execute on function whoami(jsonb) from anon, public;
grant execute on function whoami(jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- After running this file, make yourself an administrator:
--   1. Authentication > Users > Add user (your email + a password)
--   2. Run:
--      insert into app_admins (user_id, email)
--      select id, email from auth.users where email = 'you@example.org';
-- ---------------------------------------------------------------------
