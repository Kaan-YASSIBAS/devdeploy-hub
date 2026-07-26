import path from "node:path";
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

const chunkGroups: Record<string, string[]> = {
  charts: ["recharts"],
  motion: ["framer-motion"],
  react: ["react", "react-dom", "react-router"],
  i18n: ["i18next", "react-i18next", "i18next-browser-languagedetector"],
  ui: ["lucide-react", "sonner"],
  query: ["@tanstack/react-query"]
};

function manualChunks(id: string) {
  const normalizedId = id.replaceAll("\\", "/");

  for (const [chunkName, packages] of Object.entries(chunkGroups)) {
    if (packages.some((packageName) => normalizedId.includes(`/node_modules/${packageName}/`))) {
      return chunkName;
    }
  }
}

export default defineConfig({
  plugins: [react()],
  build: {
    rollupOptions: {
      output: {
        manualChunks
      }
    }
  },
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src")
    }
  }
});
