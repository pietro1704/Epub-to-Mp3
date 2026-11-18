require "application_system_test_case"

# The conversion workspace driven through its views (P-04, P-05, P-14 to P-20,
# P-24, P-25, P-27, P-28): the real Rust session, receipts, MP3 encoding and
# IndexedDB store, with the test-only fixture synthesis in place of Piper.
class ConversionWorkspaceTest < ApplicationSystemTestCase
  setup do
    # The fixture converter glue has no ConversionSession; Rust must be real.
    skip "needs the built runtime tree (CONVERTER_RUNTIME=built)" unless RuntimeFixture.built_runtime?
  end

  test "the form converts a range: tabs, hero, status, ETA and the event log follow the job" do
    visit root_path
    assert_runtime_ready
    assert_selector "#tab-progress[disabled][aria-disabled=true]"
    assert_selector "#tab-downloads[disabled][aria-disabled=true]"
    queue_sample
    steer_fixture(delayMs: 900)
    fill_in "Which chapters do you want? (optional)", with: "1-2"
    click_button "Convert now"

    assert_selector "#tab-progress[aria-selected=true]:not([disabled])"
    assert_selector "#tab-progress .tabs__badge", text: /running/i
    within("header.hero") do
      assert_selector "h1", text: "Test Multi Feature Book"
      assert_selector "[role=progressbar][aria-valuenow]"
    end
    within("#panel-progress") do
      assert_selector "[role=status]", text: "Reading and converting…"
      assert_text "Request ID:"
      assert_selector "[data-conversion-status-target=eta]", text: /calculating…|≈ \d+s|almost there/
      click_button "Show terminal output"
      assert_button "Hide terminal output"
      assert_selector "[aria-live=polite] li", text: "Converting “Test Multi Feature Book”…"
    end

    assert_selector "#tab-downloads[aria-selected=true]:not([disabled])", wait: 30
    assert_no_selector "#tab-progress .tabs__badge"
    click_button "2. Track progress"
    within("#panel-progress") do
      assert_selector "[role=status]", text: "All done!"
      assert_selector "[data-conversion-status-target=eta]", text: "finished"
      assert_selector "[data-conversion-status-target=chapters]", text: "2 of 2 chapters"
      assert_selector "[role=progressbar][aria-valuenow='100']"
      assert_selector "[aria-live=polite] li", text: "Finished conversion."
    end
    assert_operator page.evaluate_script("window.conversionFixture.requests.length"), :>=, 2
    assert_empty page.evaluate_script("window.policyViolations")
  end

  test "invalid ranges and a rejected policy show the alert without starting a job" do
    visit root_path
    assert_runtime_ready
    queue_sample
    fill_in "Which chapters do you want? (optional)", with: "3-1"
    click_button "Convert now"
    assert_selector "[role=alert]", text: "Invalid chapter range."
    fill_in "Which chapters do you want? (optional)", with: "abc"
    click_button "Convert now"
    assert_selector "[role=alert]", text: "Browser chapter selection must be a chapter number or inclusive range"
    assert_selector "#tab-progress[disabled]"

    # An Edge secondary is rejected with the explicit message, never switched (P-25).
    page.execute_script(<<~JS)
      localStorage.setItem("ebook-tts.preferences.v1", JSON.stringify({
        primary: { engine: "piper", model_id: "pt_BR-faber-medium" }, secondary: { engine: "edge", voice: "pt-BR-ThalitaNeural" },
        allow_online_fallback: true }))
    JS
    fill_in "Which chapters do you want? (optional)", with: ""
    click_button "Convert now"
    assert_selector "[role=alert]", text: "Edge is unavailable in this browser."
    assert_selector "#tab-progress[disabled]"
  end

  test "a provider failure with the system secondary fails the job and shows the error (P-25)" do
    visit root_path
    assert_runtime_ready
    queue_sample
    steer_fixture(failNext: 1)
    click_button "Convert now"
    within("#panel-progress") do
      assert_selector "[role=status]", text: "Something went wrong", wait: 15
      assert_selector "[role=alert]", text: "Details:"
      assert_no_button "Stop conversion"
    end
    assert_no_selector "#tab-progress .tabs__badge"
    assert_selector "#tab-downloads[disabled]"
    foreign = page.evaluate_script("performance.getEntriesByType('resource').map((e) => e.name).filter((n) => !n.startsWith(location.origin))")
    assert_empty foreign, "no TTS service may be contacted"
  end

  test "cancel asks first, stops the job, removes it and returns to setup" do
    visit root_path
    assert_runtime_ready
    queue_sample
    steer_fixture(delayMs: 400)
    click_button "Convert now"
    assert_selector "#tab-progress[aria-selected=true]"

    within("#panel-progress") do
      dismiss_confirm(/stops the current conversion/) { click_button "Stop conversion" }
      assert_selector "[role=status]", text: "Reading and converting…"
      accept_confirm(/stops the current conversion/) { click_button "Stop conversion" }
    end
    assert_selector "#tab-setup[aria-selected=true]", wait: 15
    assert_no_selector ".active-conversion"
    jobs = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(async ({ conversionWorkspace }) => {
        const workspace = await conversionWorkspace()
        while (workspace.state.storedRevision === 0) await new Promise((resolve) => setTimeout(resolve, 20))
        done((await workspace.client.getRecentJobs()).length)
      })
    JS
    assert_equal 0, jobs
    assert_no_selector ".job-library"
  end

  test "a reload mid-conversion lists the job as interrupted; resume finishes both chapters" do
    visit root_path
    assert_runtime_ready
    queue_sample
    steer_fixture(delayMs: 300)
    fill_in "Which chapters do you want? (optional)", with: "1-2"
    click_button "Convert now"
    # Wait until the first chapter's audio is committed, then leave the page.
    assert_selector "[data-conversion-status-target=chapters]", text: "1 of 2 chapters", wait: 30

    visit root_path
    assert_runtime_ready
    within(".job-library") do
      assert_selector ".job-library__item", text: "Test Multi Feature Book"
      assert_selector "[data-field=state]", text: "Interrupted"
      assert_selector "[data-field=progress]", text: "1 of 2 chapters"
      page.execute_script("window.conversionFixture.requests.length = 0")
      click_button "Resume now"
    end
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    outputs = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(async ({ conversionWorkspace }) => {
        done((await conversionWorkspace()).state.snapshot.outputs.map((output) => output.name))
      })
    JS
    assert_equal %w[chapter-1.mp3 chapter-2.mp3], outputs
    assert_no_selector ".job-library"
  end

  test "a batch runs in order, skip moves on, and a reload shows the saved batch that can only be dismissed" do
    visit root_path
    assert_runtime_ready
    click_button "Use sample book"
    click_button "Use sample book"
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]", count: 3
    steer_fixture(delayMs: 400)
    fill_in "Which chapters do you want? (optional)", with: "1"
    click_button "Convert now"

    assert_selector "header.hero", text: "📚 Book 1/3"
    within("#panel-progress") do
      assert_selector ".batch-queue", text: "In queue: 2 books"
      assert_selector ".batch-queue__item:first-child button:disabled", exact_text: "Move up"
      accept_confirm(/skip this book/) { click_button "Skip to next" }
    end
    assert_selector "header.hero", text: "📚 Book 2/3", wait: 15

    visit root_path
    assert_runtime_ready
    within(".saved-batch") do
      assert_text "📋 Saved queue with"
      assert_text "re-uploaded (file cannot be saved)"
      assert_no_button "Resume queue"
      click_button "Dismiss"
    end
    assert_no_selector ".saved-batch"
    visit root_path
    assert_runtime_ready
    assert_no_selector ".saved-batch"
  end

  private

  def queue_sample
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]", count: 1
  end

  # The fixture control object exists once the conversion workspace loaded it.
  def steer_fixture(**values)
    page.execute_script(<<~JS, values.to_json)
      Object.assign(window.conversionFixture ??= { failNext: 0, delayMs: 0, requests: [] }, JSON.parse(arguments[0]))
    JS
  end
end
