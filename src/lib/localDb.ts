// Local mode: a real PostgreSQL database running inside the browser
// (PGlite), saved in the browser's IndexedDB storage. It runs the very
// same migration files that are later pasted into Supabase.
import type { PGlite as PGliteType } from '@electric-sql/pglite';

const migrationFiles = import.meta.glob('../../supabase/migrations/*.sql', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>;

const DB_NAME = 'idb://bem-ledger';
let dbPromise: Promise<PGliteType> | null = null;

function migrations(): { name: string; sql: string }[] {
  return Object.entries(migrationFiles)
    .map(([path, sql]) => ({ name: path.split('/').pop()!, sql }))
    // The Supabase security layer depends on Supabase's auth schema.
    .filter((m) => !m.name.includes('supabase_security'))
    .sort((a, b) => a.name.localeCompare(b.name));
}

async function migrate(db: PGliteType) {
  await db.exec(`create table if not exists _local_migrations (name text primary key, applied_at timestamptz default now())`);
  const res = await db.query<{ name: string }>(`select name from _local_migrations`);
  const done = new Set(res.rows.map((r) => r.name));
  for (const m of migrations()) {
    // Function files are always re-applied so code changes take effect;
    // they are written with "create or replace" and are safe to re-run.
    if (done.has(m.name) && m.name.includes('schema')) continue;
    await db.exec(m.sql);
    await db.query(`insert into _local_migrations(name) values ($1) on conflict (name) do update set applied_at = now()`, [m.name]);
  }
}

export function getLocalDb(): Promise<PGliteType> {
  if (!dbPromise) {
    dbPromise = (async () => {
      const { PGlite } = await import('@electric-sql/pglite');
      const db = new PGlite(DB_NAME);
      await db.waitReady;
      await migrate(db);
      return db;
    })();
  }
  return dbPromise;
}

export async function localRpc(fn: string, p: unknown): Promise<any> {
  const db = await getLocalDb();
  const res = await db.query<{ r: any }>(`select public.${fn}($1::jsonb) as r`, [JSON.stringify(p ?? {})]);
  return res.rows[0]?.r;
}

export async function localExec(sql: string): Promise<void> {
  const db = await getLocalDb();
  await db.exec(sql);
}

// Erase everything and start again with an empty ledger.
export async function localReset(): Promise<void> {
  const db = await getLocalDb();
  await db.exec(`drop schema public cascade; create schema public;`);
  await migrate(db);
}
