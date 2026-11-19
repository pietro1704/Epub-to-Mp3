require "application_system_test_case"

# Drives the real Piper module worker of the built runtime tree (ONNX Runtime
# Web, the phonemizer and Rust MP3 encoding) without a voice model download: a
# synthetic ONNX graph with Piper's input names is written to OPFS piper/ and
# passes its "scales" input through as the audio tensor.
class PiperWorkerTest < ApplicationSystemTestCase
  SYNTHESIZE = <<~JS.freeze
    const [ done, options ] = arguments
    const run = async () => {
      const varint = (n) => { const out = []; while (n > 127) { out.push((n & 127) | 128); n = Math.floor(n / 128) } out.push(n); return out }
      const field = (number, value) => typeof value === "number" ? [ ...varint(number * 8), ...varint(value) ]
        : (() => { const body = typeof value === "string" ? [ ...new TextEncoder().encode(value) ] : value; return [ ...varint(number * 8 + 2), ...varint(body.length), ...body ] })()
      const dim = (value) => field(1, typeof value === "number" ? field(1, value) : field(2, value))
      const tensor = (name, type, dims) => [ ...field(1, name), ...field(2, field(1, [ ...field(1, type), ...field(2, dims.flatMap(dim)) ])) ]
      const graph = [
        ...field(1, [ ...field(1, "scales"), ...field(2, "output"), ...field(4, "Identity") ]), ...field(2, "synthetic-piper"),
        ...field(11, tensor("input", 7, [ 1, "n" ])), ...field(11, tensor("input_lengths", 7, [ 1 ])), ...field(11, tensor("scales", 1, [ 3 ])),
        ...field(12, tensor("output", 1, [ 3 ])),
      ]
      const model = new Uint8Array([ ...field(1, 8), ...field(8, field(2, 13)), ...field(7, graph) ])
      const config = new TextEncoder().encode(JSON.stringify({ audio: { sample_rate: 22050 }, espeak: { voice: "pt-br" },
        inference: { noise_scale: 0.25, length_scale: 0.5, noise_w: 0.75 } }))
      const piper = await (await navigator.storage.getDirectory()).getDirectoryHandle("piper", { create: true })
      for (const [ name, bytes ] of [ [ "synthetic.onnx", model ], [ "synthetic.onnx.json", config ] ]) {
        const writable = await (await piper.getFileHandle(name, { create: true })).createWritable()
        await writable.write(bytes)
        await writable.close()
      }
      const hex = async (bytes) => Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (b) => b.toString(16).padStart(2, "0")).join("")
      const revision = `${await hex(model)}:${await hex(config)}`
      const { PiperClient } = await import("runtime/piper_client")
      const base = new URL(document.querySelector('meta[name="converter-runtime-base"]').content, location.href)
      const client = new PiperClient(() => new Worker(new URL("workers/piper_worker.js", base), { type: "module" }))
      const outcome = async (promise) => promise.then((value) => ({ value }), (error) => ({ error: error.message }))
      const pinned = await outcome(client.synthesize("Olá mundo.", "synthetic", revision))
      const stale = await outcome(client.synthesize("Olá mundo.", "synthetic", "0".repeat(64) + ":" + "0".repeat(64)))
      const missing = await outcome(client.synthesize("Olá mundo.", "absent-model"))
      const audio = pinned.value?.audio
      return {
        bytes: audio?.length ?? 0, head: audio ? Array.from(audio.slice(0, 4)) : [], revision, pinned: pinned.error ?? pinned.value.modelRevision,
        voice: pinned.value?.voice, stale: stale.error, missing: missing.error, isolated: self.crossOriginIsolated,
        requests: performance.getEntriesByType("resource").map((entry) => entry.name).filter((name) => !name.startsWith(location.origin)),
      }
    }
    run().then((result) => done(JSON.stringify(result)), (error) => done(JSON.stringify({ failure: String(error?.stack ?? error) })))
  JS

  setup do
    skip "needs the built runtime tree (CONVERTER_RUNTIME=built)" unless RuntimeFixture.built_runtime?
  end

  test "the worker synthesises installed model output into Rust-encoded MP3 and enforces the pinned revision" do
    visit root_path
    assert_runtime_ready
    result = JSON.parse(page.evaluate_async_script(SYNTHESIZE))

    assert_nil result["failure"]
    assert_operator result["bytes"], :>, 0
    # An MPEG audio frame starts with an 11-bit sync word (0xFFE).
    assert_equal 0xFF, result["head"][0], "MP3 output does not start with a frame: #{result['head']}"
    assert_equal 0xE0, result["head"][1] & 0xE0
    assert_equal result["revision"], result["pinned"]
    assert_equal "0", result["voice"]
    assert_match "Installed model revision changed before preparation", result["stale"]
    assert_match(/NotFoundError|could not be found|not found/i, result["missing"])
    assert_equal false, result["isolated"]
    assert_empty result["requests"], "the worker must not fetch anything from another origin"
    assert_empty page.evaluate_script("window.policyViolations")
  end
end
