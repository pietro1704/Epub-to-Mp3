require "application_system_test_case"
require "open3"
require "tmpdir"

# Exercises the deployed React UI and the Rails UI on one Chromium origin. Each
# navigation discards the old client's JS state and blob URLs, but keeps IndexedDB.
class CrossClientStorageTest < ApplicationSystemTestCase
  test "React and Rails restore each other's sealed chapter MP3 and reject a changed blob" do
    skip "requires the built Rails conversion runtime" unless RuntimeFixture.built_runtime?

    Dir.mktmpdir("react-storage-reference") do |directory|
      build_script = Rails.root.join("test/support/build_react_storage_reference.mjs")
      log, status = Bundler.with_unbundled_env { Open3.capture2e("node", build_script.to_s, directory) }
      assert_predicate status, :success?, log
      app = Rack::URLMap.new("/react-reference" => Rack::Files.new(directory), "/" => Rails.application)
      origin = Capybara::Server.new(app).boot.base_url
      react = "#{origin}/react-reference/index.html"
      rails = "#{origin}/"
      visit react
      attach_file("file", Rails.root.join("public/sample.epub"))
      find(".form-advanced summary").click
      fill_in "chapters", with: "1"
      click_button "Convert now"
      assert_selector "a.chapter-item__download[download='chapter-1.mp3']", wait: 30
      original = react_audio("chapter-1.mp3")
      assert_positive_duration(original)
      react_record = stored_job("chapter-1.mp3")
      assert_receipt(react_record, 0)

      visit rails
      assert_runtime_ready
      restored = rails_audio(react_record.fetch("id"))
      assert_equal "finished", restored.fetch("state")
      assert_equal original, restored.fetch("audio")

      corrupt_audio(react_record.fetch("id"))
      visit rails
      assert_runtime_ready
      interrupted = rails_audio(react_record.fetch("id"))
      assert_equal "interrupted", interrupted.fetch("state")
      assert_nil interrupted.fetch("audio")
      assert_text "Interrupted"

      click_button "Use sample book"
      assert_selector ".book-queue__item[data-status=ready]"
      fill_in "Which chapters do you want? (optional)", with: "2"
      click_button "Convert now"
      assert_selector "#tab-downloads[aria-selected=true]", wait: 30
      rails_record = stored_job("chapter-2.mp3")
      assert_receipt(rails_record, 1)
      original = rails_audio(rails_record.fetch("id")).fetch("audio")
      assert_positive_duration(original)

      visit react
      find("[role=tab]", text: /Listen.*download/i).click
      find(".ready-downloads__item", text: "Test Multi Feature Book").click
      assert_equal original, react_audio("chapter-2.mp3")
      corrupt_audio(rails_record.fetch("id"))
      visit react
      assert_selector ".resumable-jobs__item .resumable-jobs__title", text: "Test Multi Feature Book"
      assert_equal "interrupted", stored_state(rails_record.fetch("id"))
    end
  end

  private

  # The reference page is a normal Vite production build with deterministic
  # synthesis I/O. Inspect its download link, independent of the Rails client.
  def react_audio(name)
    url = find("a.chapter-item__download[download='#{name}']")[:href]
    evaluate_storage("return await inspectMp3(args[0])", url)
  end

  def rails_audio(id)
    evaluate_storage(<<~JS, id)
      const { conversionWorkspace } = await import("runtime/workspace_store")
      const { client } = await conversionWorkspace()
      const snapshot = await client.fetch(args[0])
      return { state: snapshot.state, audio: snapshot.outputs.length ? await inspectMp3(snapshot.outputs[0].url) : null }
    JS
  end

  def assert_positive_duration(audio)
    assert_operator audio.fetch("duration"), :>, 0
    assert_match(/\A[\da-f]{64}\z/, audio.fetch("sha256"))
  end

  def assert_receipt(record, index)
    assert_equal "finished", record.fetch("state")
    assert_equal 1, record.fetch("databaseVersion")
    assert_equal index, record.fetch("chapter")
    assert_equal index, record.fetch("sourceIndex")
    assert_equal 2, record.fetch("receiptVersion")
    assert_equal "pt_BR-faber-medium", record.fetch("model")
    assert_match(/\A[\da-f]{64}:[\da-f]{64}\z/, record.fetch("identity"))
  end

  def stored_job(name)
    evaluate_storage(<<~JS, name)
      const db = await openDatabase()
      try {
        const jobs = await readRequest(db.transaction("jobs").objectStore("jobs").getAll())
        const job = jobs.find(entry => entry.audio.some(audio => audio.name === args[0]))
        const audio = job.audio.find(entry => entry.name === args[0])
        const receipt = audio.ttsReceipts[0]
        return { id: job.jobId, state: job.snapshot.state, chapter: audio.chapterIndex, identity: audio.cacheIdentity, model: job.preferences.primary.model_id,
          receiptVersion: receipt.version, sourceIndex: receipt.source_index, databaseVersion: db.version }
      } finally { db.close() }
    JS
  end

  def stored_state(id)
    evaluate_storage(<<~JS, id)
      const db = await openDatabase()
      try { return (await readRequest(db.transaction("jobs").objectStore("jobs").get(args[0]))).snapshot.state }
      finally { db.close() }
    JS
  end

  def corrupt_audio(id)
    evaluate_storage(<<~JS, id)
      const db = await openDatabase()
      try {
        const job = await readRequest(db.transaction("jobs").objectStore("jobs").get(args[0]))
        const audio = job.audio[0]
        const bytes = new Uint8Array(await audio.blob.arrayBuffer())
        bytes[bytes.length - 1] ^= 1
        audio.blob = new Blob([bytes], { type: audio.blob.type })
        const transaction = db.transaction("jobs", "readwrite")
        await new Promise((resolve, reject) => {
          transaction.oncomplete = resolve
          transaction.onabort = () => reject(transaction.error)
          transaction.objectStore("jobs").put(job)
        })
      } finally { db.close() }
    JS
  end

  def evaluate_storage(body, *values)
    response = page.evaluate_async_script(<<~JS, *values)
      const args = Array.from(arguments)
      const done = args.pop()
      async function inspectMp3(url) {
        const bytes = await (await fetch(url)).arrayBuffer()
        const digest = await crypto.subtle.digest("SHA-256", bytes)
        const context = new AudioContext()
        try {
          const decoded = await context.decodeAudioData(bytes)
          return { duration: decoded.duration, sha256: Array.from(new Uint8Array(digest), n => n.toString(16).padStart(2, "0")).join("") }
        } finally { await context.close() }
      }
      function readRequest(request) {
        return new Promise((resolve, reject) => {
          request.onsuccess = () => resolve(request.result)
          request.onerror = () => reject(request.error)
        })
      }
      function openDatabase() { return readRequest(indexedDB.open("ebook-tts.jobs.v1")) }
      ;(async () => { #{body} })().then(value => done({ value: value ?? null }), error => done({ error: String(error.stack ?? error) }))
    JS
    assert_nil response["error"], response["error"]
    response.fetch("value")
  end
end
