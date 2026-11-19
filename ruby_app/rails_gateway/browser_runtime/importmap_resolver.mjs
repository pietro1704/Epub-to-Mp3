// Lets node --test load page modules the way the browser does: the import map
// pins app/javascript/runtime/* under the bare "runtime/" prefix
// (config/importmap.rb), and Propshaft does not rewrite relative imports, so
// runtime modules import each other by that prefix.
import { registerHooks } from "node:module"

const RUNTIME = new URL("../app/javascript/runtime/", import.meta.url)

registerHooks({
  resolve(specifier, context, nextResolve) {
    const match = /^runtime\/([a-z0-9_]+)$/.exec(specifier)
    return match
      ? { url: new URL(`${match[1]}.js`, RUNTIME).href, format: "module", shortCircuit: true }
      : nextResolve(specifier, context)
  },
})
