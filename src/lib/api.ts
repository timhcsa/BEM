// One door to the database. Every screen calls rpc('function_name', params).
//   * Local mode (no Supabase settings): the in-browser database.
//   * Supabase mode: supabase.rpc(...) with the signed-in user's session.
// The SQL functions are identical in both, so screens never need to know.
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { localRpc, localExec, localReset } from './localDb';
import sampleDataSql from '../../supabase/sample_data.sql?raw';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const MODE: 'local' | 'supabase' = url && key ? 'supabase' : 'local';
export const supabase: SupabaseClient | null = MODE === 'supabase' ? createClient(url!, key!) : null;

const FN = /^[a-z_][a-z0-9_]*$/;

export class ApiError extends Error {}

function cleanMessage(msg: string): string {
  return (msg || 'Something went wrong')
    .replace(/^error:\s*/i, '')
    .replace(/\s*CONTEXT:[\s\S]*$/, '')
    .trim();
}

export async function rpc<T = any>(fn: string, p: Record<string, unknown> = {}): Promise<T> {
  if (!FN.test(fn)) throw new ApiError('Invalid function name');
  try {
    if (MODE === 'supabase') {
      const { data, error } = await supabase!.rpc(fn, { p });
      if (error) throw new ApiError(cleanMessage(error.message));
      return data as T;
    }
    return (await localRpc(fn, p)) as T;
  } catch (e: any) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(cleanMessage(e?.message ?? String(e)));
  }
}

// ---------------------------------------------------------------------
// Local-only data tools (Settings > Data)
// ---------------------------------------------------------------------
export async function loadSampleData() {
  if (MODE !== 'local') throw new ApiError('Sample data is only for the local test database');
  await localExec(sampleDataSql);
}

export async function resetLocalDatabase() {
  if (MODE !== 'local') throw new ApiError('Reset is only available for the local test database');
  await localReset();
}

export async function runLocalSql(sql: string) {
  if (MODE !== 'local') throw new ApiError('Only available for the local database');
  await localExec(sql);
}

// Order matters: referenced rows first. Settings last so a closed period
// does not block loading historical entries.
const TABLE_ORDER = [
  'accounts', 'funds', 'missionaries', 'payees', 'recurring_payments', 'recurring_payment_lines', 'donors', 'journal_entries', 'journal_lines', 'deposits', 'gifts',
  'gift_lines', 'disbursements', 'disbursement_lines', 'recurring_runs', 'transfers', 'reconciliations', 'reconciliation_items',
  'bank_transactions', 'audit_log', 'settings',
];
const IDENTITY: [string, string][] = [
  ['donors', 'donor_number'], ['journal_entries', 'entry_number'], ['deposits', 'deposit_number'],
  ['gifts', 'gift_number'], ['disbursements', 'disb_number'], ['audit_log', 'id'],
];

// Builds a SQL script containing all data. Run it on a fresh database
// (local or Supabase) right after the migrations to copy everything over.
export async function buildDataExportSql(): Promise<string> {
  const data = await rpc<Record<string, any[]>>('export_all_data');
  const stamp = new Date().toISOString();
  const tag = '$bemdata$';
  const parts: string[] = [
    `-- BEM Ledger data export, ${stamp}`,
    `-- Run on a NEW, EMPTY database after all migration files have been run.`,
    `-- (Supabase: SQL Editor > New query > paste > Run.)`,
    `begin;`,
    `do $$ begin if exists (select 1 from journal_entries) then raise exception 'This database already has transactions. Import into an empty database only.'; end if; end $$;`,
    `delete from audit_log; delete from settings; delete from payees; delete from missionaries; delete from funds; delete from accounts;`,
  ];
  for (const t of TABLE_ORDER) {
    const rows = data[t] ?? [];
    if (!rows.length) continue;
    const json = JSON.stringify(rows);
    if (json.includes(tag)) throw new ApiError('Data contains an unexpected marker; export cancelled');
    // new missionaries automatically get a payee; replace those with the exported ones
    if (t === 'payees') parts.push('delete from payees;');
    parts.push(`insert into ${t} select * from jsonb_populate_recordset(null::${t}, ${tag}${json}${tag}::jsonb);`);
  }
  for (const [t, c] of IDENTITY) {
    parts.push(`select setval(pg_get_serial_sequence('${t}','${c}'), greatest((select coalesce(max(${c}),0) from ${t}), 1));`);
  }
  parts.push('commit;');
  return parts.join('\n\n') + '\n';
}
