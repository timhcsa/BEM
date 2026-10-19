import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // PGlite ships its own WebAssembly build of Postgres; let Vite serve it as-is.
  optimizeDeps: { exclude: ['@electric-sql/pglite'] },
  server: { port: 5180, open: true },
});
