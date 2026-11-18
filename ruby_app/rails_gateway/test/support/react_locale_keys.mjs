// Read the original dictionaries as modules so arrays, computed values and
// multi-line functions have the same keys as the live React client.
import { readdir } from "node:fs/promises"

const directory = new URL("../../../../web/src/i18n/", import.meta.url)
function keys(value, path = []) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return [path.join(".")]
  return Object.entries(value).flatMap(([key, item]) => keys(item, [...path, key]))
}

const result = {}
for (const locale of ["pt", "en"]) {
  const names = (await readdir(directory)).filter(name => name.startsWith(locale + "_") && name.endsWith(".ts"))
  if (!names.length) throw new Error("Missing React dictionaries for " + locale)
  const catalog = {}
  for (const name of names) {
    const module = await import(new URL(name, directory))
    Object.assign(catalog, module[name.slice(0, -3)])
  }
  result[locale] = keys(catalog).sort()
}
console.log(JSON.stringify(result))
