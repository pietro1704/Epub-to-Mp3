require "application_system_test_case"
require "tmpdir"

class ChapterProgressTest < ApplicationSystemTestCase
  test "chapter audio and searchable segment text belong to the converted job" do
    skip "requires the built conversion runtime" unless RuntimeFixture.built_runtime?
    visit root_path
    assert_runtime_ready
    click_button "Use sample book"
    assert_selector ".book-queue__item[data-status=ready]"
    fill_in "Which chapters do you want? (optional)", with: "1-2"
    click_button "Convert now"
    assert_selector "#tab-downloads[aria-selected=true]", wait: 30
    click_button "2. Track progress"

    within(".chapter-progress") do
      assert_selector "details.chapter", count: 2
      first("summary").click
      within(first("details.chapter")) do
        assert_text "Done"
        assert_selector "audio.chapter-audio[src^='blob:']"
        assert_selector ".segment audio[src^='blob:']", minimum: 1
      end
      click_button "Show full text"
      segment = first(".segment p").text
      assert_predicate segment, :present?
      fill_in "Search text", with: segment[/[[:alpha:]]/]
      assert_selector "mark", minimum: 2
      count = all("mark").size
      assert_text "#{count} matches"
      click_button "Next match"
      assert_equal 1, all("mark").index(find("mark[aria-current=true]"))
      click_button "Previous match"
      assert_equal 0, all("mark").index(find("mark[aria-current=true]"))

      Dir.mktmpdir("chapter-text") do |directory|
        chromium.page.command("Page.setDownloadBehavior", behavior: "allow", downloadPath: directory)
        click_button "Download full text"
        file = Timeout.timeout(Capybara.default_max_wait_time) do
          loop do
            path = Dir.glob(File.join(directory, "book-*.txt")).first
            break path if path && File.size?(path)
            sleep 0.05
          end
        end
        assert_includes File.read(file, encoding: "UTF-8"), segment
      end
      fill_in "Search text", with: "no-such-match-30279"
      assert_text "0 matches"
      assert_button "Next match", disabled: true
    end
  end
end
