import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { inspect_epub, initSync } from "../src/wasm/converter_wasm.js";

initSync({ module: readFileSync(new URL("../src/wasm/converter_wasm_bg.wasm", import.meta.url)) });
const sample = () => readFileSync(new URL("../public/sample.epub", import.meta.url));

test("generated WASM preserves the sample EPUB identity and chapters", () => {
  const book = JSON.parse(inspect_epub(sample()));
  assert.equal(book.bookTitle, "Test Multi Feature Book");
  assert.equal(book.chapters.length, 2);
  assert.deepEqual(book.chapters.map(chapter => chapter.sourcePath), ["OEBPS/chapter1.xhtml", "OEBPS/chapter2.xhtml"]);
});

test("generated WASM rejects conflicting local and central EPUB resource names", () => {
  const bytes = sample();
  const name = Buffer.from("META-INF/container.xml");
  const offset = bytes.indexOf(name);
  assert.ok(offset >= 30);
  assert.deepEqual(bytes.subarray(offset - 30, offset - 26), Buffer.from([0x50, 0x4b, 0x03, 0x04]));
  Buffer.from("META-INF/contained.xml").copy(bytes, offset);
  assert.throws(() => inspect_epub(bytes), error => /header inconsistency/.test(String(error)));
});
