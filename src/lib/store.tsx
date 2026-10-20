import React, { createContext, useCallback, useContext, useEffect, useState } from 'react';
import { rpc } from './api';

export type Fund = {
  id: string; code: string; name: string; kind: 'general' | 'conference' | 'missionary' | 'other';
  restriction: 'without' | 'with'; admin_fee_applies: boolean; admin_fee_rate: number | null; admin_fee_cap: number | null;
  effective_fee_rate: number; effective_fee_cap: number; description: string | null; is_system: boolean; active: boolean;
  sort: number; balance: number; missionary_id: string | null; photo_url: string | null;
};
export type Account = {
  id: string; code: string; name: string; type: string; subtype: string | null; functional_class: string | null;
  description: string | null; is_system: boolean; active: boolean;
  tax_form?: string | null; reimbursable?: boolean; per_mile?: boolean;
};
export type Settings = Record<string, any>;
export type Lookups = { settings: Settings; funds: Fund[]; accounts: Account[]; missionaries: any[] };

type Ctx = {
  lookups: Lookups | null;
  refresh: () => Promise<void>;
  toast: (msg: string, kind?: 'ok' | 'error') => void;
};
const AppCtx = createContext<Ctx>(null as any);

export function AppProvider({ children }: { children: React.ReactNode }) {
  const [lookups, setLookups] = useState<Lookups | null>(null);
  const [toasts, setToasts] = useState<{ id: number; msg: string; kind: string }[]>([]);
  const refresh = useCallback(async () => { setLookups(await rpc<Lookups>('get_lookups')); }, []);
  const toast = useCallback((msg: string, kind: 'ok' | 'error' = 'ok') => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t, { id, msg, kind }]);
    setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), kind === 'error' ? 7000 : 3500);
  }, []);
  useEffect(() => { refresh().catch((e) => toast(e.message, 'error')); }, [refresh, toast]);
  return (
    <AppCtx.Provider value={{ lookups, refresh, toast }}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {toasts.map((t) => <div key={t.id} className={`toast ${t.kind}`}>{t.msg}</div>)}
      </div>
    </AppCtx.Provider>
  );
}

export const useApp = () => useContext(AppCtx);

/** Load data from an rpc and reload on demand. */
export function useRpc<T = any>(fn: string, params: Record<string, unknown> = {}, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const key = JSON.stringify(params);
  const load = useCallback(async () => {
    setLoading(true);
    try { setData(await rpc<T>(fn, params)); setError(null); }
    catch (e: any) { setError(e.message); }
    finally { setLoading(false); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fn, key, ...deps]);
  useEffect(() => { load(); }, [load]);
  return { data, error, loading, reload: load, setData };
}

// ---------------------------------------------------------------------
// Tiny hash router:  #/missionaries/<id>
// ---------------------------------------------------------------------
export function useRoute(): string[] {
  const parse = () => (window.location.hash.replace(/^#\/?/, '').split('?')[0] || 'dashboard').split('/');
  const [route, setRoute] = useState(parse);
  useEffect(() => {
    const on = () => { setRoute(parse()); window.scrollTo(0, 0); };
    window.addEventListener('hashchange', on);
    return () => window.removeEventListener('hashchange', on);
  }, []);
  return route;
}

export function routeQuery(): URLSearchParams {
  return new URLSearchParams(window.location.hash.split('?')[1] ?? '');
}

export function go(path: string) { window.location.hash = '#/' + path.replace(/^\//, ''); }
