import type { CapacitorConfig } from "@capacitor/cli";

const config: CapacitorConfig = {
  appId: "com.epubtomp3.app",
  appName: "Epub to Mp3",
  // Picks up the Vite build output (vite build --mode mobile)
  webDir: "dist",
  plugins: {
    // Use native HTTP to bypass CORS restrictions on mobile
    CapacitorHttp: {
      enabled: true,
    },
  },
};

export default config;
