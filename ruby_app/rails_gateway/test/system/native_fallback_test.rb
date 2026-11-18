require "application_system_test_case"

class NativeFallbackTest < ApplicationSystemTestCase
  setup do
    skip "requires the built conversion runtime" unless RuntimeFixture.built_runtime?
    # Chromium on CI has no OS voices. Exercise the browser's Web Speech API
    # boundary deterministically while leaving the job, receipts, UI and WASM real.
    chromium.evaluate_on_new_document(<<~JS)
      const speech = new EventTarget()
      Object.assign(speech, {
        voices: [
          { name: "Online Luciana", lang: "pt-BR", voiceURI: "online", localService: false },
          { name: "Other", lang: "pt-BR", voiceURI: "a", localService: true },
          { name: "Luciana", lang: "pt-BR", voiceURI: "z", localService: true }
        ],
        spoken: [], cancellations: 0, pauses: 0, resumes: 0,
        getVoices() { return this.voices },
        speak(utterance) { this.spoken.push(utterance); utterance.onstart() },
        cancel() { this.cancellations++ },
        pause() { this.pauses++ },
        resume() { this.resumes++ }
      })
      Object.defineProperty(window, "speechSynthesis", { value: speech })
      Object.defineProperty(window, "SpeechSynthesisUtterance", { value: class { constructor(text) { this.text = text } } })
    JS
    visit root_path
    assert_runtime_ready
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    assert_no_selector "[data-controller='native-fallback']:not([hidden])", visible: :all
    page.execute_script("window.conversionFixture.failNext = 1")
    fill_in "Which chapters do you want? (optional)", with: "1-2"
    click_button "Convert now"
    assert_selector "#panel-progress [role=status]", text: "Something went wrong", wait: 15
  end

  test "narrates only the selected source chapter, gives precedence to primary audio and retries the same Piper job" do
    before = current_job
    within("[data-controller='native-fallback']") do
      assert_text "System narration is for listening only"
      click_button "Listen with installed system voice"
      assert_text "Luciana (pt-BR)"
      assert_equal "z", page.evaluate_script("speechSynthesis.spoken.at(-1).voice.voiceURI")
      click_button "Pause"
      assert_text "System narration paused"
      click_button "Resume"
      assert_equal [ 1, 1 ], page.evaluate_script("[speechSynthesis.pauses, speechSynthesis.resumes]")
      second = all("option").last.text
      select second, from: "Chapter to narrate"
      assert_button "Listen with installed system voice", disabled: false
      click_button "Listen with installed system voice"
      assert_text "Luciana (pt-BR)"
      texts = page.evaluate_script("speechSynthesis.spoken.map(s => s.text)")
      assert_equal 2, texts.uniq.size
      page.execute_script("document.dispatchEvent(new Event('play'))")
      assert_button "Stop", disabled: true
      click_button "Listen with installed system voice"
      assert_text "Luciana (pt-BR)"
      click_button "Stop"
      assert_operator page.evaluate_script("speechSynthesis.cancellations"), :>=, 3
      assert_equal before, current_job
      assert_equal [ "failed", 0, 0 ], before.values_at("state", "chaptersCompleted", "outputs")
      click_button "Retry Piper conversion"
    end
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    assert_equal [ before.fetch("jobId"), "finished", 2, 2 ], current_job.values_at("jobId", "state", "chaptersCompleted", "outputs")
  end

  test "a missing local voice is reported, and an online voice is never used" do
    page.execute_script("speechSynthesis.voices = speechSynthesis.voices.filter(v => !v.localService)")
    within("[data-controller='native-fallback']") do
      click_button "Listen with installed system voice"
      assert_selector "[role=status]", text: "System speech is unavailable in this browser."
      assert_button "Listen with installed system voice", disabled: false
      assert_button "Stop", disabled: true
    end
    assert_equal 0, page.evaluate_script("speechSynthesis.spoken.length")
    assert_equal [ "failed", 0 ], current_job.values_at("state", "outputs")
    assert_selector "#tab-downloads[disabled]"
  end

  private

  def current_job
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(async ({ conversionWorkspace }) => {
        const workspace = await conversionWorkspace()
        const { jobId, state, chaptersCompleted, outputs } = await workspace.client.fetch(workspace.state.activeJobId)
        done({ jobId, state, chaptersCompleted, outputs: outputs.length })
      })
    JS
  end
end
