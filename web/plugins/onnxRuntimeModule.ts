import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { Plugin } from 'vite';

// ONNX dynamically imports this prebuilt companion module. Vite must serve its
// bytes unchanged, including when its dependency optimizer adds an import query.
export function onnxRuntimeModule(): Plugin {
  const modulePath = '/tts/ort-wasm-simd-threaded.mjs';
  return {
    name: 'onnx-runtime-module',
    apply: 'serve',
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (
          !server.config.publicDir ||
          !['GET', 'HEAD'].includes(request.method ?? '') ||
          request.url?.split('?')[0] !== modulePath
        ) {
          next();
          return;
        }
        void readFile(join(server.config.publicDir, modulePath.slice(1))).then(
          (bytes) => {
            response.setHeader('Content-Type', 'text/javascript');
            response.setHeader('Cache-Control', 'no-cache');
            response.end(request.method === 'HEAD' ? undefined : bytes);
          },
          (error: NodeJS.ErrnoException) => {
            if (error.code === 'ENOENT') {
              response.statusCode = 404;
              response.end();
            } else {
              next(error);
            }
          },
        );
      });
    },
  };
}
