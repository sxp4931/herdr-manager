import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "127.0.0.1",
    port: 4318,
    strictPort: true,
    proxy: {
      "/api": "http://127.0.0.1:4317",
    },
  },
  preview: {
    host: "127.0.0.1",
    port: 4318,
    strictPort: true,
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    assetsInlineLimit: 0,
  },
});
