require "application_system_test_case"

class ReaderSystemTest < ApplicationSystemTestCase
  CONTRACT = JSON.parse(Rails.root.join("test/fixtures/reader_contract.json").read).freeze

  test "a queued sample opens inline and moves into a modal without replacing its content" do
    visit root_path
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    click_button "Open reader"
    assert_reader_ready
    assert_selector "[data-reader-target=title]", text: "Test Multi Feature Book"
    assert_includes reader_text, "experimento"
    # P-44: the open is recorded as a reader-open journey in the React vocabulary.
    evidence = JSON.parse(page.evaluate_async_script(<<~JS))
      const done = arguments[0]
      import("runtime/latency_observation").then(({ latencyObservations, serializeLatencyEvidence }) =>
        done(serializeLatencyEvidence(latencyObservations.snapshot())))
    JS
    assert_equal 1, evidence["schemaVersion"]
    assert_equal [ %w[reader_open open_requested readable_content controls_usable] ],
      evidence["observations"].map { |observation| [ observation["kind"], *observation["records"].map { |record| record["transition"] } ] }
    page.execute_script("window.originalReaderHost = document.querySelector('[data-reader-target=host]')")
    within(".reader") { click_button "Open popup" }
    assert_selector "dialog[open] .reader__content"
    assert page.evaluate_script("document.querySelector('[data-reader-target=host]') === window.originalReaderHost")
    find("dialog").send_keys(:escape)
    assert_no_selector "dialog[open]"
    assert_selector "[data-reader-target=inline] .reader__content"
    assert page.evaluate_script("document.querySelector('[data-reader-target=host]') === window.originalReaderHost")
    all(".reader__chapters button").last.click
    assert_reader_ready
    assert_includes reader_text, "letter"
  end

  test "page buttons, keyboard and search navigate the mappings supplied by the runtime" do
    open_contract_book
    assert page.evaluate_script("document.activeElement.matches('[data-reader-target=article]')")
    page.save_screenshot(Rails.root.join("tmp/screenshots/reader-slice3-contract.png"), full: true)
    assert_includes reader_text, "Olá 😀 café & needle."
    click_button "Next page"
    assert_includes reader_text, "Second needle"
    find("[data-reader-target=article]").send_keys(:right)
    assert_includes reader_text, "narrated words"
    find("[data-reader-target=article]").send_keys(:left)
    assert_includes reader_text, "Second needle"

    fill_in "Search in full text…", with: "needle"
    assert_selector "[data-reader-target=matches]", text: "Match 1 of 2"
    assert_includes reader_text, "Olá 😀 café & needle."
    click_button "Next match"
    assert_selector "[data-reader-target=matches]", text: "Match 2 of 2"
    assert_includes reader_text, "Second needle"
    click_button "Previous match"
    assert_includes reader_text, "Olá 😀 café & needle."

    fill_in "Search in full text…", with: "café"
    assert_selector "[data-reader-target=matches]", text: "Match 1 of 1"
    assert_equal "café", shadow_value("querySelector('[data-reader-search]').textContent")
    projection = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({readerSession}) => done(readerSession.state.result))
    JS
    assert_includes projection.fetch("text"), "First chapter\nOlá 😀 café"
    assert_equal({ "start" => 21, "end" => 25, "pageIndex" => 0 }, projection.fetch("searchMatches").first)
    fill_in "Search in full text…", with: "chapterOlá"
    assert_selector "[data-reader-target=matches]", text: "Match 0 of 0"
    fill_in "Search in full text…", with: "missing"
    assert_selector "[data-reader-target=matches]", text: "Match 0 of 0"
    assert_button "Next match", disabled: true
    assert_button "Previous match", disabled: true
  end

  test "source structure is readable and hostile markup cannot execute or load remote resources" do
    requests = []
    chromium.page.on("Network.requestWillBeSent") { |event| requests << event.fetch("request").fetch("url") }
    open_contract_book
    assert_equal "First chapter", shadow_value("querySelector('h1').textContent")
    assert_equal "café", shadow_value("querySelector('em').textContent")
    assert_equal "Value", shadow_value("querySelector('table td').textContent")
    assert shadow_value("querySelector('img[src^=\"data:image/png\"]') !== null")
    assert_nil shadow_value("querySelector('script, iframe, [onclick], [onerror], [src^=\"http\"], [href^=\"javascript:\"]')")
    assert_nil page.evaluate_script("window.readerExecuted")
    assert requests.none? { |url| url.include?("reader-tracker.invalid") }, requests.inspect
    assert_equal "_blank", shadow_value("querySelector('a[href=\"https://example.org/\"]').target")
    assert_includes shadow_value("querySelector('a[href=\"https://example.org/\"]').rel"), "noreferrer"
    page.execute_script("document.querySelector('[data-reader-target=host]').shadowRoot.querySelector('a[data-reader-chapter]').click()")
    assert_selector "[data-reader-target=chapterName]", text: "Second chapter"
    assert_includes reader_text, "Arrival 😀."
    assert_empty page.evaluate_script("window.policyViolations")
  end

  test "reader preferences persist across reload and locale changes keep the selected book and chapter" do
    open_contract_book
    within(".reader") do
      select "Ink", from: "Reader theme"
      select "Sans-serif", from: "Font", exact: true
      uncheck "Follow audio"
    end
    page.execute_script(<<~JS)
      const input = document.querySelector('[data-preference=fontScale]')
      input.value = "1.2"
      input.dispatchEvent(new Event("input", {bubbles: true}))
    JS
    assert_reader_ready
    assert_selector ".reader__content[data-theme=ink]"
    assert_equal "1.2", page.evaluate_script("document.querySelector('[data-reader-target=host]').style.getPropertyValue('--reader-font-scale')")
    click_button "Second chapter"
    within("form[aria-label='Language']") { click_button "Portuguese" }
    assert_selector "html[lang='pt-BR']"
    assert_selector "[data-reader-target=chapterName]", text: "Second chapter"
    assert_selector ".reader__content[data-theme=ink]"
    assert_button "Abrir em popup"
    assert_empty page.evaluate_script("window.policyViolations")
    preferences = page.evaluate_script("JSON.parse(localStorage.getItem('epub-to-mp3:reader-prefs'))")
    assert_equal({ "theme" => "ink", "fontFamily" => "sans", "fontScale" => 1.2, "followAudio" => false }, preferences.slice("theme", "fontFamily", "fontScale", "followAudio"))

    visit root_path
    click_button "Usar livro de exemplo"
    assert_selector ".book-queue__item[data-status=ready]"
    click_button "Abrir leitor"
    assert_reader_ready
    assert_selector ".reader__content[data-theme=ink]"
    assert_select "Fonte", selected: "Sem serifa"
    assert_unchecked_field "Seguir áudio"
  end

  test "loading failure offers retry and a removed book invalidates pending reader work" do
    visit root_path
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({readerSession}) => {
        const inspect = readerSession.inspect
        readerSession.inspect = async () => { throw new Error("Fixture read failure") }
        window.restoreReaderInspection = () => { readerSession.inspect = inspect }
        done(true)
      })
    JS
    click_button "Open reader"
    assert_selector ".reader [role=alert]", text: "Could not load the book text."
    page.execute_script("window.restoreReaderInspection()")
    click_button "Retry loading"
    assert_reader_ready
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({readerSession}) => {
        const inspect = readerSession.inspect
        readerSession.inspect = (file) => new Promise((resolve) => { window.finishReaderInspection = async () => resolve(await inspect(file)) })
        done(true)
      })
    JS
    click_button "Open reader"
    assert_selector ".reader [data-reader-target=loading]", text: "Loading EPUB text…"
    within(".book-queue__item") { click_button "Remove" }
    page.execute_script("window.finishReaderInspection()")
    assert_no_selector ".reader:not([hidden])"
    assert_no_selector ".book-queue__item"
  end

  test "playback mappings highlight the active segment and respect manual chapter selection" do
    open_contract_book
    send_playback("1", "narrated words")
    assert_equal "narrated words", shadow_value("querySelector('[data-reader-audio]').textContent")
    assert_includes reader_text, "Final narrated words"
    click_button "Second chapter"
    assert_selector "[data-reader-target=follow]", text: "Manual reading"
    send_playback("1", "narrated words")
    assert_selector "[data-reader-target=chapterName]", text: "Second chapter"
    assert_nil shadow_value("querySelector('[data-reader-audio]')")
    send_playback("2", "narrated words")
    assert_selector "[data-reader-target=follow]", text: "Following narration"
    assert_equal "narrated words", shadow_value("querySelector('[data-reader-audio]').textContent")
    uncheck "Follow audio"
    send_playback("1", "narrated words")
    assert_selector "[data-reader-target=chapterName]", text: "Second chapter"
    assert_selector "[data-reader-target=follow]", text: "Manual reading"
  end

  test "an inspected document with no chapters presents the empty state" do
    visit root_path
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({readerSession}) => {
        readerSession.inspect = async () => ({chapters: []})
        done(true)
      })
    JS
    click_button "Open reader"
    assert_selector "[data-reader-target=empty]", text: "Select a chapter to start reading."
    assert_no_selector "[data-reader-target=loading]:not([hidden])"
    assert_no_selector "[data-reader-target=article]:not([hidden])"
  end

  private

  def open_contract_book
    visit root_path
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    # Only the document source is injected. The production reader adapter still
    # calls the runtime export, including in CONVERTER_RUNTIME=built runs.
    page.evaluate_async_script(<<~JS, CONTRACT.fetch("book"))
      const document = arguments[0], done = arguments[1]
      import("runtime/workspace_store").then(({readerSession}) => {
        readerSession.inspect = async () => document
        done(true)
      })
    JS
    click_button "Open reader"
    assert_reader_ready
  end

  def assert_reader_ready
    assert_selector ".reader[aria-busy=false] [data-reader-target=article]:not([hidden])"
  end

  def reader_text = shadow_value("querySelector('.reader-root').textContent")

  def send_playback(chapter, text)
    page.evaluate_async_script(<<~JS, chapter, text)
      const chapterIndex = arguments[0], segmentText = arguments[1], done = arguments[2]
      import("runtime/workspace_store").then(async ({readerSession}) => {
        await readerSession.followAudio({bookId: readerSession.state.bookId, chapterIndex, segmentText})
        done(true)
      })
    JS
  end

  def shadow_value(expression)
    page.evaluate_script("document.querySelector('[data-reader-target=host]').shadowRoot.#{expression}")
  end
end
