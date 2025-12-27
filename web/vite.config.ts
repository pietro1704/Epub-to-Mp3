import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";

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
    plugins: [
      react({
        // **PERFORMANCE**: Fast Refresh com optimizações
        fastRefresh: true,
      }),
    ],
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
      // **PERFORMANCE OPTIMIZATIONS**
      minify: "terser",
      terserOptions: {
        compress: {
          drop_console: true, // Remove console.log em produção
          drop_debugger: true,
          pure_funcs: ["console.log", "console.info", "console.debug"],
        },
        mangle: true,
        format: {
          comments: false, // Remove comentários
        },
      },
      rollupOptions: {
        output: {
          // **CODE SPLITTING**: Chunks otimizados
          manualChunks: {
            "react-vendor": ["react", "react-dom"],
            hooks: [
              "./src/hooks/useConversionFlow",
              "./src/hooks/useSystemStats",
            ],
          },
          // **CHUNK NAMING**: Hash para cache busting
          chunkFileNames: "assets/[name]-[hash].js",
          entryFileNames: "assets/[name]-[hash].js",
          assetFileNames: "assets/[name]-[hash].[ext]",
        },
        // **TREE SHAKING**: Otimizar imports
        treeshake: {
          moduleSideEffects: false,
          propertyReadSideEffects: false,
        },
      },
      // **PERFORMANCE**: Aumentar limite de chunk warning
      chunkSizeWarningLimit: 1000,
      // **OPTIMIZATION**: Source maps apenas para erro tracking
      sourcemap: false,
      // **CSS**: Code splitting de CSS
      cssCodeSplit: true,
      // **PRELOAD**: Otimizar module preload
      modulePreload: {
        polyfill: true,
      },
      // **TARGET**: Browsers modernos (menor bundle)
      target: ["es2020", "edge88", "firefox78", "chrome87", "safari14"],
    },
    // **OPTIMIZATION**: Otimizações de dependências
    optimizeDeps: {
      include: ["react", "react-dom"],
      esbuildOptions: {
        target: "es2020",
        // **PERFORMANCE**: Minificação de dependências
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
