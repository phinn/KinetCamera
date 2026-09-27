import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  server: {
    port: 5174,
    proxy: {
      '/api': 'http://localhost:3311',
      '/socket.io': { target: 'http://localhost:3311', ws: true },
    },
  },
});
