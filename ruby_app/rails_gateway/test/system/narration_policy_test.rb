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

  test "starting another conversion restores the saved voice independently of the download target" do
    skip "needs the Rust model catalog" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    assert_select "Primary voice", selected: "Faber medium"
    find("summary", text: "Model downloads").click
    assert_unchecked_field "Show low-quality models"
    assert_select "Model to download", selected: "Faber medium"
    uncheck "Use preferences"
    select "pt_BR-cadu-medium", from: "Voice for this conversion"
    assert_select "Model to download", selected: "Faber medium"
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    fill_in "Which chapters do you want? (optional)", with: "1"
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    click_button "Start another conversion"
    assert_checked_field "Use preferences"
    assert_no_select "Voice for this conversion"
    assert_select "Primary voice", selected: "Faber medium"
    assert_select "Model to download", selected: "Faber medium"
  end

  test "showing Low downloads does not add an uninstalled Low narration voice" do
    skip "needs the Rust model catalog" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    supports_manual = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/converter_runtime")
        .then(({ loadTtsCatalog }) => loadTtsCatalog(true))
        .then(catalog => done(catalog.models.some(model => model.manual_only)), () => done(false))
    JS
    skip "needs the manual Rust model catalog" unless supports_manual
    find("summary", text: "Model downloads").click
    assert_no_selector "[data-model-install-target=model] option[value=pt_BR-edresson-low]", visible: :all
    check "Show low-quality models"
    assert_selector "[data-model-install-target=model] option[value=pt_BR-edresson-low]", visible: :all
    select "pt_BR-edresson-low", from: "Model to download"
    assert_select "Primary voice", selected: "Faber medium"
    assert_no_selector "[data-narration-policy-target] option[value=pt_BR-edresson-low]", visible: :all
    uncheck "Show low-quality models"
    assert_no_selector "[data-model-install-target=model] option[value=pt_BR-edresson-low]", visible: :all
    assert_empty page.evaluate_script("performance.getEntriesByType('resource').filter(e => e.name.includes('huggingface.co'))")
  end

  test "a locally installed Low voice remains an explicit primary after closing the filter and reloading" do
    skip "exercises local browser installation with the test catalog and fixture artifacts" if RuntimeFixture.built_runtime?
    model_id = "pt_BR-fixture-low"
    download_option = "[data-model-install-target=model] option[value='#{model_id}']"
    primary_option = "[data-narration-policy-target=primary] option[value='#{model_id}']"
    secondary_option = "[data-narration-policy-target=secondary] option[value='#{model_id}']"

    visit root_path
    assert_runtime_ready
    find("summary", text: "Model downloads").click
    assert_unchecked_field "Show low-quality models"
    assert_no_selector download_option, visible: :all
    assert_no_selector primary_option, visible: :all
    check "Show low-quality models"
    select model_id, from: "Model to download"
    assert_select "Primary voice", selected: "Faber medium"
    assert_no_selector primary_option, visible: :all
    assert_empty page.evaluate_script("performance.getEntriesByType('resource').filter(entry => /low-model\.(data|json)$/.test(entry.name))")

    click_button "Install selected model"
    assert_text "Selected model installed"
    assert_selector primary_option, visible: :all
    assert_select "Primary voice", selected: "Faber medium"
    assert_no_selector secondary_option, visible: :all
    select model_id, from: "Primary voice"

    revision = page.evaluate_script("JSON.parse(localStorage.getItem('ebook-tts.preferences.v1')).primary.session.model_revision")
    artifact_directory = Rails.root.join("test/fixtures/converter_runtime/wasm")
    assert_equal %w[low-model.data low-model.json].map { |file| Digest::SHA256.file(artifact_directory.join(file)).hexdigest }.join(":"), revision
    resources = page.evaluate_script("performance.getEntriesByType('resource').map(entry => entry.name)")
    assert_equal %w[low-model.data low-model.json], resources.grep(/low-model\.(data|json)$/).map { |url| File.basename(url) }.sort
    assert_empty resources.grep(/huggingface\.co/)

    uncheck "Show low-quality models"
    assert_no_selector download_option, visible: :all
    assert_select "Primary voice", selected: model_id
    assert_no_selector secondary_option, visible: :all

    visit root_path
    assert_runtime_ready
    assert_select "Primary voice", selected: model_id
    assert_no_selector secondary_option, visible: :all
    find("summary", text: "Model downloads").click
    assert_unchecked_field "Show low-quality models"
    assert_no_selector download_option, visible: :all
    assert_empty page.evaluate_script("performance.getEntriesByType('resource').filter(entry => /low-model\.(data|json)$/.test(entry.name))")
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
      find("summary", text: "Model downloads").click
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
