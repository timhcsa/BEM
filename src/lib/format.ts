const usd = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });

export function money(v: unknown): string {
  const n = Number(v ?? 0);
  if (!isFinite(n)) return '—';
  return usd.format(n);
}

/** Accounting style: negatives in parentheses. */
export function acct(v: unknown): string {
  const n = Number(v ?? 0);
  if (n < 0) return `(${usd.format(-n)})`;
  return usd.format(n);
}

export function num(v: unknown): number {
  const n = Number(String(v ?? '').replace(/[$,\s]/g, ''));
  return isFinite(n) ? n : 0;
}

export function today(): string {
  const d = new Date();
  return toISO(d);
}

export function toISO(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function date(v: string | null | undefined): string {
  if (!v) return '';
  const [y, m, d] = String(v).slice(0, 10).split('-').map(Number);
  return new Date(y, m - 1, d).toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function monthLabel(ym: string): string {
  const [y, m] = ym.split('-').map(Number);
  return new Date(y, m - 1, 1).toLocaleDateString('en-US', { month: 'short' });
}

export type Period = { from: string; to: string; label: string };

export function periods(): Record<string, Period> {
  const now = new Date();
  const y = now.getFullYear();
  const m = now.getMonth();
  const first = (yy: number, mm: number) => toISO(new Date(yy, mm, 1));
  const last = (yy: number, mm: number) => toISO(new Date(yy, mm + 1, 0));
  return {
    this_month: { from: first(y, m), to: today(), label: 'This month' },
    last_month: { from: first(y, m - 1), to: last(y, m - 1), label: 'Last month' },
    this_quarter: { from: first(y, Math.floor(m / 3) * 3), to: today(), label: 'This quarter' },
    ytd: { from: `${y}-01-01`, to: today(), label: 'Year to date' },
    last_year: { from: `${y - 1}-01-01`, to: `${y - 1}-12-31`, label: 'Last year' },
  };
}

export const METHODS: Record<string, string> = {
  check: 'Check', cash: 'Cash', online: 'Online', ach: 'ACH / bank transfer', card: 'Card', stock: 'Stock', other: 'Other',
};
export const PAY_METHODS: Record<string, string> = {
  check: 'Check', ach: 'ACH / direct deposit', debit_card: 'Debit card', wire: 'Wire', bank_fee: 'Bank charge', other: 'Other',
};
export const DONOR_TYPES: Record<string, string> = {
  individual: 'Individual', household: 'Household / couple', church: 'Church', organization: 'Organization',
  foundation: 'Foundation', business: 'Business',
};
export const FUNCTIONAL: Record<string, string> = {
  program: 'Program', management_general: 'Management & general', fundraising: 'Fundraising',
};

export function toCsv(rows: Record<string, unknown>[], columns: [string, string][]): string {
  const esc = (v: unknown) => {
    const s = v == null ? '' : String(v);
    return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return [columns.map((c) => esc(c[1])).join(','), ...rows.map((r) => columns.map((c) => esc(r[c[0]])).join(','))].join('\n');
}

export function download(filename: string, content: string, type = 'text/plain') {
  const blob = new Blob([content], { type });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 500);
}

/** Resize an uploaded photo to a small JPEG data URL (stored in the database). */
export function resizeImage(file: File, max = 480): Promise<string> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    const reader = new FileReader();
    reader.onload = () => { img.src = String(reader.result); };
    reader.onerror = reject;
    img.onload = () => {
      const scale = Math.min(1, max / Math.max(img.width, img.height));
      const c = document.createElement('canvas');
      c.width = Math.round(img.width * scale);
      c.height = Math.round(img.height * scale);
      c.getContext('2d')!.drawImage(img, 0, 0, c.width, c.height);
      resolve(c.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = () => reject(new Error('That file could not be read as an image'));
    reader.readAsDataURL(file);
  });
}

export function initials(name: string): string {
  const w = name.split(/[\s&]+/).filter((x) => /^[A-Za-z]/.test(x));
  if (!w.length) return '?';
  return (w[0][0] + (w.length > 1 ? w[w.length - 1][0] : '')).toUpperCase();
}
