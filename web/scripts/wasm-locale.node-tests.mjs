import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { ConversionSession, initSync } from "../src/wasm/converter_wasm.js";

initSync({ module: readFileSync(new URL("../src/wasm/converter_wasm_bg.wasm", import.meta.url)) });

const chapters = () => [{ index: 4, text: "Olá. Este capítulo mantém a voz escolhida." }];
const preferences = () => ({
  policy_version: 2,
  primary: { engine: "piper", model_id: "pt_BR-faber-medium", voice: null },
  secondary: { engine: "system", model_id: null, voice: null },
  allow_online_fallback: false,
});

function rejectsEnglish(policy) {
  let session;
  try {
    assert.throws(() => {
      session = new ConversionSession(JSON.stringify(chapters()), JSON.stringify(policy), "en");
    }, error => {
      assert.match(String(error), /Faber medium supports Portuguese/);
      return true;
    });
  } finally {
    session?.free();
  }
}

test("browser MP3 export rejects incompatible Faber even with native listening fallback", () => {
  rejectsEnglish(preferences());
});

test("browser MP3 export preserves strict English rejection without a secondary", () => {
  const policy = preferences();
  delete policy.policy_version;
  policy.secondary = null;
  rejectsEnglish(policy);
});

test("Portuguese export captures its Piper identity independently of later preference edits", () => {
  const policy = preferences();
  const input = chapters();
  const session = new ConversionSession(JSON.stringify(input), JSON.stringify(policy), "pt-BR");
  try {
    policy.primary.engine = "system";
    policy.primary.model_id = null;
    policy.secondary = null;
    input[0].index = 99;
    input[0].text = "Changed after submission.";
    const segment = JSON.parse(session.next_segment());
    assert.equal(segment.chapter, 4);
    assert.equal(segment.index, 0);
    assert.equal(segment.text, "Olá. Este capítulo mantém a voz escolhida.");
    assert.equal(segment.fallback_used, false);
    assert.deepEqual(segment.selection, {
      engine: "piper", model_id: "pt_BR-faber-medium", voice: null,
    });
  } finally {
    session.free();
  }
});
