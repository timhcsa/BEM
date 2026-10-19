// Combines the migration files into one file you can paste into the
// Supabase SQL Editor:  npm run sql:bundle  ->  supabase/deploy_all.sql
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
const dir = 'supabase/migrations';
const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
const out = files.map((f) => `-- >>> ${f}\n${readFileSync(`${dir}/${f}`, 'utf8')}`).join('\n\n');
writeFileSync('supabase/deploy_all.sql', out);
console.log(`Wrote supabase/deploy_all.sql from ${files.length} files`);
