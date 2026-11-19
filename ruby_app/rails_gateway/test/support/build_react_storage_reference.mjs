// Build the React application for the Rails cross-client IndexedDB system test.
// The production application, WASM, job writer, receipts and restore code run
// unchanged. Only installed-model verification and the Piper worker are test I/O.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const web = new URL('../../../../web/', import.meta.url);
const webRoot = fileURLToPath(web);
const { build } = await import(createRequire(new URL('package.json', web)).resolve('vite'));
const synthesis = fileURLToPath(new URL('./react_storage_synthesis.js', import.meta.url));
const [outDir] = process.argv.slice(2);
if (!outDir) throw new Error('Expected a temporary output directory');
process.chdir(webRoot);
await build({
  root: webRoot,
  base: '/react-reference/',
  publicDir: false,
  plugins: [
    {
      name: 'storage-test-synthesis',
      enforce: 'pre',
      resolveId(source, importer) {
        if (
          importer?.endsWith('/services/BrowserConversionRuntime.ts') &&
          (source === './BrowserPiper' || source === './BrowserModelIntegrity')
        )
          return synthesis;
      },
    },
  ],
  build: { outDir, emptyOutDir: false },
});
