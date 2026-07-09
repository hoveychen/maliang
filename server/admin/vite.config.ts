import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// base=/debug/：构建产物由 server 在 /debug 下托管（静态资源路径随之）。
// dev 时 API/资产代理到本地 server（默认 :8080），页面开 http://localhost:5173/debug/
export default defineConfig({
  plugins: [react()],
  base: '/debug/',
  server: {
    proxy: {
      '/debug/api': 'http://localhost:8080',
      '/debug/state': 'http://localhost:8080',
      '/assets': 'http://localhost:8080',
    },
  },
  build: { outDir: 'dist' },
});
