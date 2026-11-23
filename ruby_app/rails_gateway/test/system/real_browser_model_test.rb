require "application_system_test_case"
require "uri"

# The opt-in workflow uses an isolated browser profile and the immutable Rust
# catalog URLs. It exercises real browser model storage, synthesis and MP3 decoding.
class RealBrowserModelTest < ApplicationSystemTestCase
  test "an explicit install verifies Faber and converts the sample with the production worker" do
    skip "run the separate real-model validation" unless ENV["REAL_BROWSER_MODEL"] == "1"
    assert_predicate RuntimeFixture, :built_runtime?
    requests = []
    chromium.on("Network.requestWillBeSent") do |params|
      url = params.dig("request", "url")
      requests << URI.parse(url).host if url&.start_with?("https://")
    end
    visit root_path
    assert_runtime_ready
    assert_no_selector "meta[name=conversion-test-fixture]", visible: :all
    assert_empty requests
    # #1318 moved the installer into the collapsed "Model downloads" section.
    find("summary", text: "Model downloads").click
    click_button "Install selected model"
    assert_selector "[data-install-state=installed]", wait: 150
    assert_equal [ "huggingface.co", "us.aws.cdn.hf.co" ], requests.uniq.sort
    artifacts = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const hashes = async () => {
        const root = await (await navigator.storage.getDirectory()).getDirectoryHandle("piper")
        return Promise.all(["pt_BR-faber-medium.onnx", "pt_BR-faber-medium.onnx.json"].map(async name => {
          const file = await (await root.getFileHandle(name)).getFile()
          const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", await file.arrayBuffer()))
          return { name, bytes: file.size, sha256: Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("") }
        }))
      }
      hashes().then(done, error => done(String(error)))
    JS
    assert_equal [ 63_201_294, 4_855 ], artifacts.pluck("bytes")
    assert_equal %w[858555e3a064209c57088fe6bd70c4c3dc54d03eaa00c45d5ecaf43a33f95aa7 7e694de195ae3fc36dd732c445eb04fb49b649854893cb5506b978f0d50a1d6f], artifacts.pluck("sha256")
    visit root_path
    assert_selector "[data-install-state=installed]", wait: 25
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    fill_in "Which chapters do you want? (optional)", with: "1-2"
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 300
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const decode = async () => {
        const { conversionWorkspace } = await import("runtime/workspace_store")
        const { state } = await conversionWorkspace()
        const ctx = new AudioContext()
        try {
          return await Promise.all(state.snapshot.outputs.map(async output => {
            const audio = await ctx.decodeAudioData(await (await fetch(output.url)).arrayBuffer())
            return { name: output.name, seconds: audio.duration, audible: audio.getChannelData(0).some(value => Math.abs(value) > 0.001) }
          }))
        } finally { await ctx.close() }
      }
      decode().then(done, error => done(String(error)))
    JS
    assert_equal %w[chapter-1.mp3 chapter-2.mp3], result.pluck("name")
    assert result.all? { |entry| entry["seconds"] > 1 && entry["audible"] }
    assert_equal false, page.evaluate_script("crossOriginIsolated")
    assert_empty page.evaluate_script("window.policyViolations")
    report = { artifacts: artifacts, download_hosts: requests.uniq.sort, outputs: result, cross_origin_isolated: false }
    Rails.root.join("tmp/real-browser-model.json").write(JSON.pretty_generate(report))
  end
end
