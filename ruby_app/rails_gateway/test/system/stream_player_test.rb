require "application_system_test_case"

class StreamPlayerTest < ApplicationSystemTestCase
  setup do
    skip "requires the built conversion runtime" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
  end

  test "playback starts during conversion and a chapter jump steers synthesis and reaches audible audio" do
    # Each long chapter requires multiple Rust segments. The independent markers in the
    # fixture provider's input identify exactly which chapter was synthesized after a jump.
    page.execute_script(<<~JS)
      import("runtime/workspace_store").then(async ({ conversionWorkspace }) => {
        const workspace = await conversionWorkspace()
        window.conversionFixture.delayMs = 650
        const chapters = ["Alpha", "Bravo", "Charlie"].map(name => ({ name, text: (name + " travels in the morning. ").repeat(150) }))
        window.playerEvents = []
        document.addEventListener("player:segment", ({ detail }) => {
          if (detail) window.playerEvents.push({ ...detail, phase: workspace.state.phase })
        })
        window.latency = (await import("runtime/latency_observation")).latencyObservations
        workspace.submit([{ document: { bookTitle: "Travel journal", bookAuthor: "Traveler", language: "pt-BR", chapters } }])
      })
    JS
    within(".streaming-player") do
      click_button "Listen now (sequential streaming)"
      assert_button "Previous chapter", disabled: true
      select "1.5x", from: "Speed"
      assert_text "Alpha travels", wait: 25
      assert_selector "li[aria-current=true]"
      assert_equal "1.5", page.evaluate_script("localStorage.getItem('epub-to-mp3:player-speed')")
      assert_equal [ "Travel journal", "Traveler" ], page.evaluate_script("[navigator.mediaSession.metadata.title, navigator.mediaSession.metadata.artist]")
      assert_player_journey("progressive_playback", "audio_audible")
      assert_equal "converting", page.evaluate_script("window.playerEvents[0].phase")
      click_button "Next chapter"
      assert_equal "1", find_field("Jump to").value
      click_button "Previous chapter"
      assert_equal "0", find_field("Jump to").value
      # Record the boundary before the real DOM change to distinguish an old in-flight request.
      page.execute_script(<<~JS)
        document.querySelector("[data-player-target=chapter]").addEventListener("change", () => {
          window.seekRequestBoundary = window.conversionFixture.requests.length
        }, { capture: true, once: true })
      JS
      select "Charlie", from: "Jump to"
      assert_button "Next chapter", disabled: true
      assert_text "Charlie travels", wait: 25
      assert_player_journey("seek", "seek_target_reached")
      first_after_seek = page.evaluate_script("window.conversionFixture.requests[window.seekRequestBoundary].text")
      assert_includes first_after_seek, "Charlie travels"
      click_button "Stop"
      assert_button "Listen now (sequential streaming)"
      job_id = page.evaluate_script("window.playerEvents[0].jobId")
      position = page.evaluate_script("JSON.parse(localStorage.getItem('epub-to-mp3:player-pos:' + arguments[0]))", job_id)
      assert_equal 2, position.fetch("chapterIndex")
      click_button "Listen now (sequential streaming)"
      assert_equal "2", find_field("Jump to").value
      assert_equal "1.5", find_field("Speed").value
      click_button "Stop"
      assert_no_selector "audio[src]", visible: :all
    end
  end

  test "stopping playback removes only its own highlight from the open reader" do
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    click_button "Open reader"
    assert_selector "[data-reader-target=article]"
    page.execute_script(<<~JS)
      import("runtime/workspace_store").then(async ({ bookQueue, conversionWorkspace, readerSession }) => {
        const [book] = bookQueue.snapshot()
        const workspace = await conversionWorkspace()
        window.testReader = readerSession
        // Pause on the actual media event to keep the short fixture segment on screen.
        document.addEventListener("playing", event => event.target.pause(), true)
        const documentCopy = { ...book.document, chapters: [{ ...book.document.chapters[0], text: "experimento" }] }
        workspace.submit([{ bookId: book.id, document: documentCopy }])
      })
    JS
    assert_selector "#tab-downloads[aria-selected=true]"
    click_button "2. Track progress"
    click_button "Listen now (sequential streaming)"
    assert_equal "experimento", reader_audio_mark("experimento")
    click_button "Stop"
    assert_equal "", reader_audio_mark("")

    click_button "Listen now (sequential streaming)"
    assert_equal "experimento", reader_audio_mark("experimento")
    page.execute_script(<<~JS)
      window.testReader.followAudio({ ...window.testReader.playback, segmentText: "itálico" })
    JS
    assert_equal "itálico", reader_audio_mark("itálico")
    click_button "Stop"
    assert_equal "itálico", reader_audio_mark("itálico")
  end

  private

  def reader_audio_mark(expected)
    page.evaluate_async_script(<<~JS, expected)
      const [expected, done] = arguments
      const deadline = performance.now() + 3500
      const timer = setInterval(() => {
        const mark = document.querySelector("[data-reader-target=host]").shadowRoot?.querySelector("[data-reader-audio]")?.textContent ?? ""
        if (mark === expected || performance.now() > deadline) { clearInterval(timer); done(mark) }
      }, 20)
    JS
  end

  def assert_player_journey(kind, last_transition)
    result = page.evaluate_async_script(<<~JS, kind, last_transition)
      const [kind, last, done] = arguments
      const deadline = performance.now() + 10000
      const timer = setInterval(() => {
        const journey = window.latency.snapshot().find(entry => entry.kind === kind && entry.terminal && entry.records.at(-1).transition === last)
        if (journey || performance.now() > deadline) { clearInterval(timer); done(journey?.records.map(event => event.transition) ?? []) }
      }, 25)
    JS
    assert_equal(kind == "seek" ? %w[seek_requested seek_target_reached] : %w[play_requested audio_queued audio_playable audio_audible], result)
  end
end
