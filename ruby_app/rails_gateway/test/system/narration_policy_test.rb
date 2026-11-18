require "application_system_test_case"

class NarrationPolicyTest < ApplicationSystemTestCase
  test "a catalog override captures only this conversion while defaults survive reloading" do
    skip "needs the Rust model catalog" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    assert_select "Primary voice", selected: "Faber medium"
    assert_select "Secondary voice", selected: I18n.t("form.ttsPreferences.system", locale: :en)
    select "pt_BR-jeff-medium", from: "Primary voice"
    assert_select "Secondary voice", selected: "None"
    select "Faber medium", from: "Secondary voice"
    uncheck "Use preferences"
    select "pt_BR-cadu-medium", from: "Voice for this conversion"
    check "Allow secondary for this conversion"
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    fill_in "Which chapters do you want? (optional)", with: "1"
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    model = page.evaluate_script("window.conversionFixture.requests[0].modelId")
    assert_equal "pt_BR-cadu-medium", model
    visit root_path
    assert_select "Primary voice", selected: "pt_BR-jeff-medium"
    assert_select "Secondary voice", selected: "Faber medium"
    assert_checked_field "Use preferences"
    assert_empty page.evaluate_script("performance.getEntriesByType('resource').filter(e => e.name.includes('huggingface.co'))")
  end

  test "starting another conversion restores the saved voice and the model install target" do
    skip "needs the Rust model catalog" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    assert_select "Primary voice", selected: "Faber medium"
    uncheck "Use preferences"
    select "pt_BR-cadu-medium", from: "Voice for this conversion"
    assert_selector "#narration-policy[data-model-install-model-value='pt_BR-cadu-medium']"
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    fill_in "Which chapters do you want? (optional)", with: "1"
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    click_button "Start another conversion"
    assert_checked_field "Use preferences"
    assert_no_select "Voice for this conversion"
    assert_select "Primary voice", selected: "Faber medium"
    assert_selector "#narration-policy[data-model-install-model-value='pt_BR-faber-medium']"
  end

  test "blocked browser storage reports how to open the Space directly without downloading" do
    skip "needs the Rust model catalog" unless RuntimeFixture.built_runtime?
    chromium.evaluate_on_new_document(<<~JS)
      Object.defineProperty(navigator.storage, "getDirectory", { value: async () => {
        throw new DOMException("Storage access denied", "SecurityError")
      } })
    JS
    visit root_path
    assert_runtime_ready
    within("#narration-policy") do
      assert_text "Browser model storage is unavailable."
      click_button "Install selected model"
      assert_text "open the Space directly in its own tab"
    end
    assert_empty page.evaluate_script("performance.getEntriesByType('resource').filter(e => e.name.includes('huggingface.co'))")
  end

  test "a corrupt staged download leaves existing OPFS files and other voices intact" do
    visit root_path
    assert_runtime_ready
    result = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      const exercise = async () => {
        const { installArtifacts } = await import("runtime/model_installation")
        const directory = await (await navigator.storage.getDirectory()).getDirectoryHandle("installation-test", { create: true })
        const files = { "voice.onnx": "old weights", "other.onnx": "other voice" }
        for (const [name, value] of Object.entries(files)) {
          const writer = await (await directory.getFileHandle(name, { create: true })).createWritable()
          await writer.write(value)
          await writer.close()
        }
        const bytes = new TextEncoder().encode("valid")
        const hash = Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("")
        const model = { id: "voice", artifacts: ["voice.onnx","voice.onnx.json"].map(name => ({ name, url: name, bytes: 5, sha256: hash })) }
        let error
        try { await installArtifacts(model, directory, async url => new Response(url.endsWith(".json") ? "wrong" : "valid")) }
        catch (failure) { error = String(failure) }
        const retained = {}
        for await (const [name, handle] of directory) retained[name] = await (await handle.getFile()).text()
        return { error, retained }
      }
      exercise().then(done, error => done(String(error)))
    JS
    assert_includes result.fetch("error"), "checksum validation failed"
    assert_equal({ "voice.onnx" => "old weights", "other.onnx" => "other voice" }, result.fetch("retained"))
  end
end
