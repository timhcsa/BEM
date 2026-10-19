// CSV parsing and donor column mapping for imports.

/** Parse CSV text (RFC 4180: quotes, embedded commas/newlines, CRLF, BOM). */
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let i = 0;
  let inQuotes = false;
  const s = text.replace(/^\uFEFF/, '');
  const firstLine = s.split('\n')[0] ?? '';
  const delim = firstLine.includes('\t') && !firstLine.includes(',') ? '\t' : ',';
  while (i < s.length) {
    const c = s[i];
    if (inQuotes) {
      if (c === '"') {
        if (s[i + 1] === '"') { field += '"'; i += 2; continue; }
        inQuotes = false; i++; continue;
      }
      field += c; i++; continue;
    }
    if (c === '"') { inQuotes = true; i++; continue; }
    if (c === delim) { row.push(field); field = ''; i++; continue; }
    if (c === '\r') { i++; continue; }
    if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; i++; continue; }
    field += c; i++;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((v) => v.trim() !== ''));
}

export const DONOR_FIELDS: [string, string][] = [
  ['donor_number', 'Donor #'], ['donor_type', 'Type'], ['full_name', 'Full name (will be split)'],
  ['first_name', 'First name'], ['spouse_name', 'Spouse first name'], ['last_name', 'Last name'],
  ['organization_name', 'Organization name'], ['contact_name', 'Contact person'], ['salutation', 'Salutation'],
  ['email', 'Email'], ['phone', 'Phone'], ['address_line1', 'Address'], ['address_line2', 'Address 2'],
  ['city', 'City'], ['state', 'State'], ['postal_code', 'ZIP'], ['country', 'Country'],
  ['church_affiliation', 'Home church'], ['receipt_preference', 'Receipts'], ['is_anonymous', 'Anonymous'], ['notes', 'Notes'],
];

const SYNONYMS: Record<string, string[]> = {
  donor_number: ['donor #', 'donor number', 'donor id', 'id', 'donor no', 'constituent id'],
  donor_type: ['type', 'donor type', 'kind'],
  full_name: ['name', 'full name', 'donor name', 'donor', 'display name'],
  first_name: ['first name', 'first', 'firstname', 'given name', 'fname'],
  spouse_name: ['spouse first name', 'spouse', 'spouse name', 'partner'],
  last_name: ['last name', 'last', 'lastname', 'surname', 'family name', 'lname'],
  organization_name: ['organization name', 'organization', 'org', 'org name', 'company', 'company name', 'church name', 'business name'],
  contact_name: ['contact person', 'contact', 'contact name', 'attention', 'attn'],
  salutation: ['salutation', 'greeting', 'dear', 'addressee'],
  email: ['email', 'e-mail', 'email address', 'e-mail address'],
  phone: ['phone', 'phone number', 'telephone', 'mobile', 'cell', 'home phone'],
  address_line1: ['address', 'address 1', 'address line 1', 'address1', 'street', 'street address', 'mailing address'],
  address_line2: ['address 2', 'address line 2', 'address2', 'apt', 'suite', 'unit'],
  city: ['city', 'town'],
  state: ['state', 'st', 'province', 'state/province'],
  postal_code: ['zip', 'zip code', 'zipcode', 'postal code', 'postcode', 'zip/postal code'],
  country: ['country'],
  church_affiliation: ['home church', 'church', 'church affiliation'],
  receipt_preference: ['receipts', 'receipt preference', 'send receipts by', 'receipt method'],
  is_anonymous: ['anonymous', 'is anonymous'],
  notes: ['notes', 'note', 'comments', 'memo'],
};

/** Guess which donor field each CSV column holds. */
export function autoMap(headers: string[]): string[] {
  const used = new Set<string>();
  return headers.map((h) => {
    const k = h.trim().toLowerCase().replace(/[_]+/g, ' ').replace(/\s+/g, ' ');
    const hit = Object.entries(SYNONYMS).find(([f, syn]) => !used.has(f) && (syn.includes(k) || f === k.replace(/ /g, '_')));
    if (hit) { used.add(hit[0]); return hit[0]; }
    return '';
  });
}

const TYPE_WORDS: Record<string, string> = {
  individual: 'individual', person: 'individual', household: 'household', 'household / couple': 'household', couple: 'household',
  family: 'household', church: 'church', organization: 'organization', org: 'organization', foundation: 'foundation',
  business: 'business', company: 'business',
};
const ORG_RE = /\b(church|baptist|chapel|ministr|fellowship|tabernacle|assembly|foundation|trust|inc|llc|company|co\.|corp)\b/i;

/** Turn one CSV row (already mapped to field names) into a donor record. */
export function toDonor(raw: Record<string, string>): Record<string, any> {
  const d: Record<string, any> = {};
  for (const [k, v] of Object.entries(raw)) if (k && v != null && String(v).trim() !== '') d[k] = String(v).trim();

  if (d.full_name && !d.first_name && !d.last_name && !d.organization_name) {
    const n = d.full_name;
    if (ORG_RE.test(n)) d.organization_name = n;
    else {
      // "Robert & Linda Anderson" / "Robert and Linda Anderson" / "Anderson, Robert"
      if (n.includes(',')) { const [last, first] = n.split(',').map((x: string) => x.trim()); d.last_name = last; d.first_name = first; }
      else {
        const parts = n.split(/\s+/);
        d.last_name = parts.pop();
        const rest = parts.join(' ');
        const m = rest.match(/^(.+?)\s+(?:&|and)\s+(.+)$/i);
        if (m) { d.first_name = m[1]; d.spouse_name = m[2]; } else if (rest) d.first_name = rest;
      }
    }
  }
  delete d.full_name;

  const t = d.donor_type ? TYPE_WORDS[String(d.donor_type).toLowerCase()] ?? String(d.donor_type).toLowerCase() : null;
  if (t) d.donor_type = t;
  else if (d.organization_name && !d.first_name && !d.last_name) d.donor_type = /church|baptist|chapel|fellowship|tabernacle|assembly/i.test(d.organization_name) ? 'church' : /foundation|trust/i.test(d.organization_name) ? 'foundation' : 'organization';
  else d.donor_type = d.spouse_name ? 'household' : 'individual';
  if (d.donor_type === 'individual' && d.spouse_name) d.donor_type = 'household';

  if (d.receipt_preference) {
    const r = String(d.receipt_preference).toLowerCase();
    d.receipt_preference = r.startsWith('e') ? 'email' : r.startsWith('m') || r.startsWith('p') ? 'mail' : r.startsWith('n') || r.startsWith('d') ? 'none' : r;
  }
  if ('is_anonymous' in d) d.is_anonymous = /^(y|yes|true|1|x)$/i.test(d.is_anonymous);
  if (d.email) d.email = String(d.email).toLowerCase();
  if (d.state && d.state.length <= 3) d.state = d.state.toUpperCase();
  if (d.postal_code && /^\d{4}$/.test(d.postal_code)) d.postal_code = '0' + d.postal_code; // Excel drops leading zeros
  return d;
}

/** Columns used for both export and the import template, so a file can round-trip. */
export const DONOR_EXPORT_COLUMNS: [string, string][] = [
  ['donor_number', 'Donor #'], ['donor_type', 'Type'], ['first_name', 'First name'], ['spouse_name', 'Spouse first name'],
  ['last_name', 'Last name'], ['organization_name', 'Organization name'], ['contact_name', 'Contact person'],
  ['salutation', 'Salutation'], ['email', 'Email'], ['phone', 'Phone'], ['address_line1', 'Address'], ['address_line2', 'Address 2'],
  ['city', 'City'], ['state', 'State'], ['postal_code', 'ZIP'], ['country', 'Country'], ['church_affiliation', 'Home church'],
  ['receipt_preference', 'Receipts'], ['is_anonymous', 'Anonymous'], ['notes', 'Notes'],
];
