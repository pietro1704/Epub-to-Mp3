import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

import { readFileSync } from "fs";

const pkg = JSON.parse(readFileSync("./package.json", "utf-8")) as {
  version: string;
};

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const rawApiBase = (env.VITE_API_BASE || "").trim();
  const proxyOverride = (env.VITE_API_PROXY_TARGET || "").trim();
  const backendPort = (env.VITE_BACKEND_PORT || env.PORT || "8000").trim();
  const fallbackTarget = `http://127.0.0.1:${backendPort}`;
  const proxyTarget = /^https?:\/\//i.test(rawApiBase)
    ? rawApiBase
    : /^https?:\/\//i.test(proxyOverride)
      ? proxyOverride
      : fallbackTarget;

  return {
    define: {
      __APP_VERSION__: JSON.stringify(pkg.version),
    },
    plugins: [react()],
    publicDir: "public",
    server: {
      proxy: {
        "/api": {
          target: proxyTarget,
          changeOrigin: true,
          timeout: 120000,
        },
        "/sample.epub": {
          target: proxyTarget,
          changeOrigin: true,
        },
        "/api/uploads": {
          target: proxyTarget,
          changeOrigin: true,
        },
      },
    },
    build: {
      outDir: "dist",
      emptyOutDir: true,
      minify: "terser",
      terserOptions: {
        compress: {
          drop_console: true,
          drop_debugger: true,
          pure_funcs: ["console.log", "console.info", "console.debug"],
        },
        mangle: true,
        format: {
          comments: false,
        },
      },
      rollupOptions: {
        output: {
          manualChunks(id: string) {
            if (
              id.includes("node_modules/react") ||
              id.includes("node_modules/react-dom")
            ) {
              return "react-vendor";
            }
            if (
              id.includes("/src/hooks/useConversionFlow") ||
              id.includes("/src/hooks/useSystemStats")
            ) {
              return "hooks";
            }
            return undefined;
          },
          chunkFileNames: "assets/[name]-[hash].js",
          entryFileNames: "assets/[name]-[hash].js",
          assetFileNames: "assets/[name]-[hash].[ext]",
        },
        treeshake: {
          moduleSideEffects: false,
          propertyReadSideEffects: false,
        },
      },
      chunkSizeWarningLimit: 1000,
      sourcemap: false,
      cssCodeSplit: true,
      modulePreload: {
        polyfill: true,
      },
      target: ["es2020", "edge88", "firefox78", "chrome87", "safari14"],
    },
    optimizeDeps: {
      include: ["react", "react-dom"],
      rolldownOptions: {
        target: "es2020",
        minify: true,
      },
    },
    test: {
      globals: true,
      environment: "jsdom",
      setupFiles: "./src/test/setupTests.ts",
      css: true,
    },
  };
});
