require "application_system_test_case"

class BookSelectionTest < ApplicationSystemTestCase
  SAMPLE = Rails.root.join("public/sample.epub").freeze

  test "choosing EPUBs inspects locally, orders, removes and requires a ready book" do
    requests = []
    chromium.page.on("Network.requestWillBeSent") { |event| requests << event.fetch("request") }
    visit root_path
    assert_runtime_ready

    click_button "Convert now"
    assert_selector "[role=alert]", text: "Choose an EPUB file before converting."
    attach_file "Book file (EPUB)", SAMPLE
    assert_ready_books 1
    assert_selector ".book-queue__item", text: "Test Multi Feature Book"
    assert_selector ".book-queue__item", text: "Equipe de Testes"
    click_button "Use sample book"
    assert_ready_books 2

    ids = queue_ids
    within(all(".book-queue__item").last) { click_button "Move up" }
    assert_equal ids.reverse, queue_ids
    within(all(".book-queue__item").first) { click_button "Move down" }
    assert_equal ids, queue_ids
    within(all(".book-queue__item").first) { click_button "Remove" }
    assert_ready_books 1
    assert_equal [ ids.last ], queue_ids

    # Includes resources, XHR/fetch and form navigation; no book action posts.
    assert requests.all? { |request| request["method"] == "GET" }, requests.inspect
    assert requests.none? { |request| request["hasPostData"] }, requests.inspect
    assert_empty page.evaluate_script("window.policyViolations")
  end

  test "dropping files and choosing a folder use the same local queue" do
    visit root_path
    assert_runtime_ready
    page.execute_script(<<~JS)
      fetch("/sample.epub").then((response) => response.blob()).then((bytes) => {
        const transfer = new DataTransfer()
        transfer.items.add(new File([bytes], "dropped.epub", {type: "application/epub+zip"}))
        document.querySelector(".book-picker").dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: transfer}))
        const folder = document.querySelector("[data-book-picker-target=folder]")
        const files = new DataTransfer()
        files.items.add(new File([bytes], "folder.epub", {type: "application/epub+zip"}))
        folder.files = files.files
        folder.dispatchEvent(new Event("change", {bubbles: true}))
      })
    JS
    assert_ready_books 2
    assert_selector ".book-queue__item", text: "dropped.epub"
    assert_selector ".book-queue__item", text: "folder.epub"
    ids = queue_ids
    page.execute_script(<<~JS)
      const rows = document.querySelectorAll(".book-queue__item")
      const transfer = new DataTransfer()
      rows[1].dispatchEvent(new DragEvent("dragstart", {bubbles: true, dataTransfer: transfer}))
      rows[0].dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: transfer, clientY: rows[0].getBoundingClientRect().top}))
    JS
    assert_equal ids.reverse, queue_ids
  end

  test "theme and locale round trips retain the queue, files and metadata" do
    visit root_path
    click_button "Use sample book"
    assert_ready_books 1
    ids = queue_ids
    within("form[aria-label='Theme']") { click_button "Light" }
    assert_selector "html.theme-light"
    assert_ready_books 1
    within("form[aria-label='Language']") { click_button "Portuguese" }
    assert_selector "html[lang='pt-BR']"
    assert_ready_books 1
    assert_equal ids, queue_ids
    assert_selector ".book-queue__item", text: "Metadados detectados. Pronto."
    assert_button "Converter agora"
    byte_count = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({bookQueue}) => bookQueue.snapshot()[0].file.arrayBuffer()).then((bytes) => done(bytes.byteLength))
    JS
    assert_equal File.size(SAMPLE), byte_count
  end

  test "invalid files stay out, inspection errors stay visible and do not validate" do
    visit root_path
    assert_runtime_ready
    page.execute_script(<<~JS)
      const files = new DataTransfer()
      files.items.add(new File(["pdf"], "unsupported.pdf"))
      files.items.add(new File([new Blob([new Uint8Array(100 * 1024 * 1024 + 1)])], "large.epub"))
      files.items.add(new File(["invalid zip"], "broken.epub"))
      document.querySelector(".book-picker").dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: files}))
    JS
    assert_selector "[role=alert]", text: "Only EPUB files are supported."
    assert_selector "[role=alert]", text: "File exceeds the 100 MB limit."
    assert_selector ".book-queue__item[data-status=error]", count: 1
    assert_selector ".book-queue__item [role=alert]"
    click_button "Convert now"
    assert_selector "[role=alert]", text: "Choose an EPUB file before converting."
    assert_no_selector "[role=tab][aria-selected=true]", text: "2. Track progress"
  end

  test "validation waits for inspection and a removed pending book cannot reappear" do
    visit root_path
    assert_runtime_ready
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("runtime/workspace_store").then(({bookQueue}) => {
        const inspect = bookQueue.inspect
        let release
        const gate = new Promise((resolve) => { release = resolve })
        window.releaseInspection = release
        bookQueue.inspect = async (file) => { await gate; return inspect(file) }
        done(true)
      })
    JS
    attach_file "Book file (EPUB)", SAMPLE
    assert_selector ".book-queue__item[data-status=uploading]", count: 1
    click_button "Convert now"
    assert_button "Waiting for book inspection…", disabled: true
    click_button "Remove"
    page.execute_script("window.releaseInspection()")
    assert_no_selector ".book-queue__item"
    assert_button "Convert now", disabled: false
    assert_selector "[role=alert]", text: "Choose an EPUB file before converting."
  end

  test "sample fetch failure reports an error without adding a book" do
    chromium.network.intercept(pattern: "*/sample.epub")
    chromium.on(:request) { |request| request.abort }
    visit root_path
    assert_runtime_ready
    click_button "Use sample book"
    assert_selector "[data-book-picker-target=error]", text: "Unable to load the sample book."
    assert_no_selector ".book-queue__item"
    assert_button "Use sample book", disabled: false
  end

  test "Portuguese validation and sample errors use the current locale after Turbo preserves the queue" do
    visit root_path
    click_button "Use sample book"
    assert_ready_books 1
    ids = queue_ids

    within("form[aria-label='Language']") { click_button "Portuguese" }
    assert_selector "html[lang='pt-BR']"
    assert_ready_books 1
    assert_equal ids, queue_ids
    assert_selector ".book-queue__item", text: "Metadados detectados. Pronto."

    page.execute_script(<<~JS)
      const files = new DataTransfer()
      files.items.add(new File(["pdf"], "unsupported.pdf"))
      files.items.add(new File([new Uint8Array(100 * 1024 * 1024 + 1)], "large.epub"))
      document.querySelector(".book-picker").dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: files}))
    JS
    assert_selector "[role=alert]", text: "unsupported.pdf: Apenas arquivos EPUB são aceitos."
    assert_selector "[role=alert]", text: "large.epub: O arquivo excede o limite de 100 MB."
    assert_ready_books 1
    assert_equal ids, queue_ids

    chromium.network.intercept(pattern: "*/sample.epub")
    chromium.on(:request) { |request| request.abort }
    click_button "Usar livro de exemplo"
    assert_selector "[data-book-picker-target=error]", text: "Não foi possível carregar o livro de exemplo."
    assert_button "Usar livro de exemplo", disabled: false
    assert_ready_books 1
    assert_equal ids, queue_ids

    click_button "Remover"
    click_button "Converter agora"
    assert_selector "[role=alert]", text: "Escolha um arquivo EPUB antes de converter."
  end

  private

  def assert_ready_books(count)
    assert_selector ".book-queue__item[data-status=ready]", count: count
    assert_selector "[data-book-picker-target=count]", text: count.to_s, exact_text: true
  end

  def queue_ids = all(".book-queue__item").map { |row| row["data-book-id"] }
end
