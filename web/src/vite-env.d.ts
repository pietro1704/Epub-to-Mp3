/// <reference types="vite/client" />

declare const __APP_VERSION__: string;

declare module '@diffusionstudio/piper-wasm/build/piper_phonemize.js' {
  export default function createPiperPhonemize(options: {
    print(message: string): void;
    printErr(message: string): void;
    locateFile(name: string): string;
  }): Promise<{ callMain(arguments_: string[]): void }>;
}
