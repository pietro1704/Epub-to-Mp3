require "application_system_test_case"
require "tmpdir"

class DownloadsTest < ApplicationSystemTestCase
  setup do
    skip "requires the built conversion runtime" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    convert_range("1-2")
  end

  test "chapter MP3s play exclusively, download as files and share the selected output" do
    within(".downloads-panel") do
      assert_selector "audio", count: 2
      assert_selector "a[download='chapter-1.mp3'][href^='blob:']"
      assert_selector "a[download='chapter-2.mp3'][href^='blob:']"
      # The fixture audio lasts 0.2s. Loop each track so the exclusivity assertion
      # observes two overlapping playback requests, not a natural end.
      states = page.evaluate_async_script(<<~JS)
        const done = arguments[0], players = Array.from(document.querySelectorAll(".downloads-panel audio"))
        for (const player of players) { player.loop = true; player.muted = true }
        ;(async () => {
          await players[0].play()
          const firstPlaying = !players[0].paused
          await players[1].play()
          done([firstPlaying, players[0].paused, players[1].paused])
        })().catch(error => done(String(error)))
      JS
      assert_equal [ true, true, false ], states

      page.execute_script(<<~JS)
        window.shareCalls = []
        Object.defineProperty(navigator, "share", { configurable: true, value: async payload => window.shareCalls.push(payload) })
        Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async url => window.copied = url } })
        window.open = (...args) => { window.opened = args }
      JS
      first_url = find("a[download='chapter-1.mp3']")[:href]
      click_button "Share…"
      assert_equal first_url, page.evaluate_script("shareCalls.at(-1).url")
      assert_equal "Test Multi Feature Book", page.evaluate_script("shareCalls.at(-1).title")
      click_button "Copy link"
      assert_text "Link copied!"
      assert_equal first_url, page.evaluate_script("window.copied")
      click_button "Share on WhatsApp"
      assert_includes page.evaluate_script("decodeURIComponent(window.opened[0])"), first_url
      page.execute_script("Object.defineProperty(navigator, 'share', {value: async () => { throw new Error('unsupported') }})")
      click_button "Share…"
      assert_text "Your browser could not open the share sheet."
    end

    Dir.mktmpdir("downloaded-chapters") do |directory|
      chromium.page.command("Page.setDownloadBehavior", behavior: "allow", downloadPath: directory)
      click_button "Download all chapters"
      assert_downloaded_mp3s(directory, %w[chapter-1.mp3 chapter-2.mp3])
    end
  end

  test "recent jobs survive reload; switching jobs and clearing the form preserve the correct saved audio" do
    subject_id = find("[data-downloads-target=readyList] button[aria-pressed=true]")["data-job-id"]
    click_button "Start another conversion"
    assert_selector "#tab-setup[aria-selected=true]"
    assert_no_selector ".book-queue__item"
    assert_field "Which chapters do you want? (optional)", with: ""
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    convert_range("2")
    within("[data-downloads-target=readyList]") do
      assert_selector "li", count: 2
      within("li[data-job-id='#{subject_id}']") { click_button "Open downloads" }
    end
    within(".downloads-panel") do
      assert_text "Listening to “Test Multi Feature Book”"
      assert_selector "a[download]", count: 2
      click_button "Back to current downloads"
      assert_selector "a[download='chapter-2.mp3']"
      assert_no_selector "a[download='chapter-1.mp3']"
    end
    visit root_path
    assert_runtime_ready
    assert_selector ".recent-jobs li", count: 2
    within(".recent-jobs") do
      find("summary").click
      assert_no_button "Listen"
      find("summary").click
      within("li[data-job-id='#{subject_id}']") { click_button "Listen" }
    end
    assert_selector "#tab-downloads[aria-selected=true]"
    assert_selector ".downloads-panel audio", count: 2
    within("[data-downloads-target=readyList] li[data-job-id='#{subject_id}']") { click_button "Remove" }
    assert_selector "#tab-setup[aria-selected=true]"
    assert_selector ".recent-jobs li", count: 1
    assert_includes page.evaluate_script("JSON.parse(localStorage.getItem('ebook-tts-hidden-recent'))"), subject_id
    visit root_path
    assert_runtime_ready
    assert_selector ".recent-jobs li", count: 1
    assert_no_selector ".recent-jobs [data-job-id='#{subject_id}']"
  end

  private

  def convert_range(range)
    fill_in "Which chapters do you want? (optional)", with: range
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    assert_selector ".downloads-panel audio", minimum: 1
  end

  def assert_downloaded_mp3s(directory, names)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until names.all? { |name| File.size?(File.join(directory, name)) }
      flunk "Missing MP3 download in #{Dir.children(directory)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    names.each do |name|
      link = find(".downloads-panel a[download='#{name}']")[:href]
      size = page.evaluate_async_script("const [url, done] = arguments; fetch(url).then(r => r.blob()).then(b => done(b.size))", link)
      assert_operator size, :>, 0
      assert_equal size, File.size(File.join(directory, name))
    end
  end
end
