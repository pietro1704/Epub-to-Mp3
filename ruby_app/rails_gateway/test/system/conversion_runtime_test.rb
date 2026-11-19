require "application_system_test_case"

# Converts sample.epub through the production conversion objects of the page
# (real Rust ConversionSession, receipts, MP3 encoding, IndexedDB store and
# restore validation) with the test-only fixture synthesis in place of model
# verification and Piper inference.
class ConversionRuntimeTest < ApplicationSystemTestCase
  CONVERT = <<~JS.freeze
    const [ range, done ] = arguments
    const run = async () => {
      const { conversionWorkspace, inspectBook } = await import("runtime/workspace_store")
      const bytes = await (await fetch("/sample.epub")).blob()
      const document = await inspectBook(new File([ bytes ], "sample.epub", { type: "application/epub+zip" }))
      const workspace = await conversionWorkspace()
      await workspace.submit([ { document, chapters: range, fileName: "sample.epub" } ])
      const { snapshot, phase, tab } = workspace.state
      const heads = await Promise.all(snapshot.outputs.map(async (output) =>
        Array.from(new Uint8Array(await (await fetch(output.url)).arrayBuffer()).slice(0, 2))))
      return {
        phase, tab, state: snapshot.state, error: snapshot.error, names: snapshot.outputs.map((output) => output.name), heads,
        chapters: document.chapters.length, requests: window.conversionFixture.requests.length,
        isolated: self.crossOriginIsolated,
        foreign: performance.getEntriesByType("resource").map((entry) => entry.name).filter((name) => !name.startsWith(location.origin)),
      }
    }
    run().then((result) => done(JSON.stringify(result)), (error) => done(JSON.stringify({ failure: String(error?.stack ?? error) })))
  JS

  RESTORE = <<~JS.freeze
    const [ done ] = arguments
    const run = async () => {
      const { conversionWorkspace } = await import("runtime/workspace_store")
      const { client } = await conversionWorkspace()
      const jobs = await client.getRecentJobs()
      const snapshot = jobs[0] && await client.fetch(jobs[0].jobId)
      return { jobs: jobs.length, state: snapshot?.state, outputs: snapshot?.outputs.map((output) => output.name) }
    }
    run().then((result) => done(JSON.stringify(result)), (error) => done(JSON.stringify({ failure: String(error?.stack ?? error) })))
  JS

  setup do
    # The fixture converter glue has no ConversionSession; Rust must be real.
    skip "needs the built runtime tree (CONVERTER_RUNTIME=built)" unless RuntimeFixture.built_runtime?
  end

  test "a two-chapter range converts to one MP3 per chapter and survives a reload with its audio" do
    visit root_path
    assert_runtime_ready
    result = JSON.parse(page.evaluate_async_script(CONVERT, "1-2"))

    assert_nil result["failure"]
    assert_operator result["chapters"], :>=, 2
    assert_nil result["error"]
    assert_equal "finished", result["state"]
    assert_equal [ "finished", "downloads" ], [ result["phase"], result["tab"] ]
    assert_equal %w[chapter-1.mp3 chapter-2.mp3], result["names"]
    result["heads"].each do |head|
      assert_equal 0xFF, head[0]
      assert_equal 0xE0, head[1] & 0xE0
    end
    assert_operator result["requests"], :>=, 2
    assert_equal false, result["isolated"]
    assert_empty result["foreign"], "conversion must not contact another origin"

    visit root_path
    assert_runtime_ready
    restored = JSON.parse(page.evaluate_async_script(RESTORE))

    assert_nil restored["failure"]
    assert_equal 1, restored["jobs"]
    # Sealed audio identity is recomputed with the real cache material on restore.
    assert_equal "finished", restored["state"]
    assert_equal %w[chapter-1.mp3 chapter-2.mp3], restored["outputs"]
    assert_empty page.evaluate_script("window.policyViolations")
  end
end
